use std::collections::HashMap;

use serde_json::Map;

use crate::shared::protocol::content::{AssistantContent, ThinkingContentKind};
use crate::shared::protocol::events::AssistantMessage;
use crate::shared::protocol::messages::ToolInvocationDraft;

#[derive(Clone, Debug)]
enum OrderedContentBlock {
    Text(String),
    Thinking {
        thinking: String,
        kind: ThinkingContentKind,
        signature: Option<String>,
    },
    ToolInvocation {
        draft: ToolInvocationDraft,
        finalized: bool,
    },
}

/// Canonical assistant content builder keyed by the order stream blocks first
/// appeared. Provider final payloads are still useful for token metadata, but
/// content replay uses this order once the provider has emitted real streamed
/// content so live, reconnect, and persisted views agree.
#[derive(Clone, Debug, Default)]
pub(super) struct OrderedAssistantContent {
    blocks: Vec<OrderedContentBlock>,
    active_text_index: Option<usize>,
    active_thinking_index: Option<usize>,
    tool_indices: HashMap<String, usize>,
}

impl OrderedAssistantContent {
    pub(super) fn new() -> Self {
        Self::default()
    }

    pub(super) fn is_empty(&self) -> bool {
        self.content_blocks().is_empty()
    }

    pub(super) fn start_text(&mut self) {
        if self.active_text_index.is_some() {
            return;
        }
        if matches!(self.blocks.last(), Some(OrderedContentBlock::Text(_))) {
            self.active_text_index = Some(self.blocks.len() - 1);
            return;
        }
        let idx = self.blocks.len();
        self.blocks.push(OrderedContentBlock::Text(String::new()));
        self.active_text_index = Some(idx);
    }

    pub(super) fn append_text(&mut self, delta: &str) {
        if self.active_text_index.is_none() {
            self.start_text();
        }
        if let Some(idx) = self.active_text_index
            && let Some(OrderedContentBlock::Text(text)) = self.blocks.get_mut(idx)
        {
            text.push_str(delta);
        }
    }

    pub(super) fn finish_text(&mut self, text: &str) {
        if self.active_text_index.is_none() {
            self.start_text();
        }
        if let Some(idx) = self.active_text_index.take()
            && let Some(OrderedContentBlock::Text(current)) = self.blocks.get_mut(idx)
        {
            current.clear();
            current.push_str(text);
        }
    }

    pub(super) fn close_text(&mut self) {
        self.active_text_index = None;
    }

    pub(super) fn start_thinking(&mut self, kind: ThinkingContentKind) {
        if self.active_thinking_index.is_some() {
            return;
        }
        if matches!(
            self.blocks.last(),
            Some(OrderedContentBlock::Thinking { .. })
        ) {
            self.active_thinking_index = Some(self.blocks.len() - 1);
            return;
        }
        let idx = self.blocks.len();
        self.blocks.push(OrderedContentBlock::Thinking {
            thinking: String::new(),
            kind,
            signature: None,
        });
        self.active_thinking_index = Some(idx);
    }

    pub(super) fn append_thinking(&mut self, delta: &str, kind: ThinkingContentKind) {
        if self.active_thinking_index.is_none() {
            self.start_thinking(kind);
        }
        if let Some(idx) = self.active_thinking_index
            && let Some(OrderedContentBlock::Thinking { thinking, .. }) = self.blocks.get_mut(idx)
        {
            thinking.push_str(delta);
        }
    }

    pub(super) fn finish_thinking(
        &mut self,
        thinking: &str,
        kind: ThinkingContentKind,
        signature: Option<String>,
    ) {
        if self.active_thinking_index.is_none() {
            // Some providers emit a terminal full-snapshot ThinkingEnd after
            // they have already started a tool invocation. The
            // invocation closes the active block to preserve ordering, so
            // finalize the matching streamed block instead of appending the
            // same thinking again after the invocation.
            self.active_thinking_index = self.blocks.iter().rposition(|block| {
                matches!(
                    block,
                    OrderedContentBlock::Thinking {
                        thinking: current,
                        ..
                    } if current == thinking
                )
            });
            if self.active_thinking_index.is_none() {
                self.start_thinking(kind);
            }
        }
        if let Some(idx) = self.active_thinking_index.take()
            && let Some(OrderedContentBlock::Thinking {
                thinking: current,
                kind: current_kind,
                signature: current_signature,
            }) = self.blocks.get_mut(idx)
        {
            current.clear();
            current.push_str(thinking);
            *current_kind = kind;
            *current_signature = signature;
        }
    }

    pub(super) fn start_tool_invocation(&mut self, id: &str, name: &str) {
        self.active_text_index = None;
        self.active_thinking_index = None;

        if let Some(idx) = self.tool_indices.get(id).copied() {
            if let Some(OrderedContentBlock::ToolInvocation { draft, .. }) =
                self.blocks.get_mut(idx)
                && draft.name.is_empty()
            {
                draft.name = name.to_owned();
            }
            return;
        }

        let idx = self.blocks.len();
        self.blocks.push(OrderedContentBlock::ToolInvocation {
            draft: ToolInvocationDraft::new(id.to_owned(), name.to_owned(), Map::new()),
            finalized: false,
        });
        let _ = self.tool_indices.insert(id.to_owned(), idx);
    }

    pub(super) fn finish_tool_invocation(&mut self, draft: &ToolInvocationDraft) {
        if let Some(idx) = self.tool_indices.get(&draft.id).copied() {
            if let Some(OrderedContentBlock::ToolInvocation {
                draft: current,
                finalized,
            }) = self.blocks.get_mut(idx)
            {
                *current = draft.clone();
                *finalized = true;
            }
            return;
        }

        let idx = self.blocks.len();
        self.blocks.push(OrderedContentBlock::ToolInvocation {
            draft: draft.clone(),
            finalized: true,
        });
        let _ = self.tool_indices.insert(draft.id.clone(), idx);
    }

    pub(super) fn content_blocks(&self) -> Vec<AssistantContent> {
        self.blocks
            .iter()
            .filter_map(|block| match block {
                OrderedContentBlock::Text(text) => {
                    let trimmed = text.trim_end();
                    (!trimmed.is_empty()).then(|| AssistantContent::text(trimmed))
                }
                OrderedContentBlock::Thinking {
                    thinking,
                    kind,
                    signature,
                } => (!thinking.is_empty()).then(|| AssistantContent::Thinking {
                    thinking: thinking.clone(),
                    kind: *kind,
                    signature: signature.clone(),
                }),
                OrderedContentBlock::ToolInvocation { draft, finalized } => {
                    finalized.then(|| AssistantContent::ToolInvocation {
                        id: draft.id.clone(),
                        name: draft.name.clone(),
                        arguments: draft.arguments.clone(),
                        thought_signature: draft.thought_signature.clone(),
                    })
                }
            })
            .collect()
    }

    pub(super) fn into_message(
        self,
        token_usage: Option<crate::shared::protocol::messages::TokenUsage>,
    ) -> AssistantMessage {
        AssistantMessage {
            content: self.content_blocks(),
            token_usage,
        }
    }
}

/// Finalize an in-progress tool invocation from accumulated deltas.
pub(super) fn finalize_tool_invocation(
    tool_invocations: &mut Vec<ToolInvocationDraft>,
    current_id: &mut Option<String>,
    current_name: &mut Option<String>,
    current_args: &mut String,
) -> Option<ToolInvocationDraft> {
    if let (Some(id), Some(name)) = (current_id.take(), current_name.take()) {
        if current_args.trim().is_empty() {
            current_args.clear();
            return None;
        }
        let arguments: Map<String, serde_json::Value> = match serde_json::from_str(current_args) {
            Ok(map) => map,
            Err(e) => {
                tracing::warn!(
                    component = "agent.stream",
                    agent_event = "stream_tool_invocation_arguments_malformed",
                    tool_name = %name,
                    invocation_id = %id,
                    error = %e,
                    args_len = current_args.len(),
                    "malformed tool invocation arguments, using empty map"
                );
                Map::new()
            }
        };
        let draft = ToolInvocationDraft::new(id.clone(), name.clone(), arguments);
        if let Some(pos) = tool_invocations.iter().position(|tc| tc.id == id) {
            tool_invocations[pos] = draft.clone();
        } else {
            tool_invocations.push(draft.clone());
        }
        current_args.clear();
        return Some(draft);
    }
    None
}

/// Build an `AssistantMessage` from accumulated parts.
pub(super) fn build_message(
    text: &str,
    thinking: &str,
    thinking_signature: Option<&str>,
    tool_invocations: &[ToolInvocationDraft],
) -> AssistantMessage {
    let mut content: Vec<AssistantContent> = Vec::with_capacity(3);

    if !thinking.is_empty() {
        content.push(AssistantContent::Thinking {
            thinking: thinking.to_owned(),
            kind: ThinkingContentKind::Thinking,
            signature: thinking_signature.map(String::from),
        });
    }

    if !text.is_empty() {
        let trimmed = text.trim_end();
        if !trimmed.is_empty() {
            content.push(AssistantContent::text(trimmed));
        }
    }

    for tc in tool_invocations {
        content.push(AssistantContent::ToolInvocation {
            id: tc.id.clone(),
            name: tc.name.clone(),
            arguments: tc.arguments.clone(),
            thought_signature: tc.thought_signature.clone(),
        });
    }

    AssistantMessage {
        content,
        token_usage: None,
    }
}
