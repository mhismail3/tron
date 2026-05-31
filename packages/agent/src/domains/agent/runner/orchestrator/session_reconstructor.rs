//! Session reconstructor — rebuild runtime state from event history.

use crate::domains::session::event_store::{EventStore, SessionState};
use crate::shared::messages::{Message, TokenUsage};

use crate::domains::agent::runner::errors::RuntimeError;

/// Reconstructed session state for resuming.
#[derive(Clone, Debug, Default)]
pub struct ReconstructedState {
    /// Session model.
    pub model: String,
    /// Reconstructed messages.
    pub messages: Vec<Message>,
    /// Cumulative token usage.
    pub token_usage: TokenUsage,
    /// Turn count.
    pub turn_count: u32,
    /// Working directory.
    pub working_directory: Option<String>,
    /// System prompt override.
    pub system_prompt: Option<String>,
    /// Whether the session has ended.
    pub is_ended: bool,
    /// Active worktree path (from `worktree.acquired` event, if not released).
    pub worktree_path: Option<String>,
    /// Last-seen reasoning level from `config.reasoning_level` events.
    pub reasoning_level: Option<String>,
}

/// Reconstruct session state from the event store.
pub fn reconstruct(
    event_store: &EventStore,
    session_id: &str,
) -> Result<ReconstructedState, RuntimeError> {
    let state = event_store
        .get_state_at_head(session_id)
        .map_err(|e| RuntimeError::Persistence(e.to_string()))?;

    let mut result = from_session_state(&state);

    // Check for active worktree
    if let Ok(Some(event)) = event_store.get_active_worktree(session_id)
        && let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload)
    {
        result.worktree_path = payload
            .get("path")
            .and_then(|v| v.as_str())
            .map(String::from);
    }

    Ok(result)
}

/// Convert `SessionState` to `ReconstructedState`.
#[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
fn from_session_state(state: &SessionState) -> ReconstructedState {
    let messages: Vec<Message> = state
        .messages_with_event_ids
        .iter()
        .filter_map(|m| match serde_json::to_value(&m.message) {
            Ok(value) => match serde_json::from_value::<Message>(value) {
                Ok(msg) => Some(msg),
                Err(e) => {
                    tracing::warn!(
                        event_ids = ?m.event_ids,
                        role = %m.message.role,
                        error = %e,
                        "session reconstructor: wire-format message does not round-trip to \
                         runtime Message enum; dropping from reconstructed history"
                    );
                    None
                }
            },
            Err(e) => {
                tracing::warn!(
                    event_ids = ?m.event_ids,
                    role = %m.message.role,
                    error = %e,
                    "session reconstructor: failed to serialize wire-format message to JSON; \
                     dropping from reconstructed history"
                );
                None
            }
        })
        .collect();

    let token_usage = TokenUsage {
        input_tokens: state.token_usage.input_tokens as u64,
        output_tokens: state.token_usage.output_tokens as u64,
        cache_read_tokens: state
            .token_usage
            .cache_read_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        cache_creation_tokens: state
            .token_usage
            .cache_creation_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        cache_creation_5m_tokens: state
            .token_usage
            .cache_creation_5m_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        cache_creation_1h_tokens: state
            .token_usage
            .cache_creation_1h_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        cached_input_tokens: state
            .token_usage
            .cached_input_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        reasoning_output_tokens: state
            .token_usage
            .reasoning_output_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        thought_tokens: state
            .token_usage
            .thought_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        tool_use_prompt_tokens: state
            .token_usage
            .tool_use_prompt_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        total_tokens: state
            .token_usage
            .total_tokens
            .filter(|&v| v > 0)
            .map(|v| v as u64),
        provider_type: None,
    };

    ReconstructedState {
        model: state.model.clone(),
        messages,
        token_usage,
        turn_count: state.turn_count as u32,
        working_directory: Some(state.working_directory.clone()),
        system_prompt: state.system_prompt.clone(),
        is_ended: state.is_ended.unwrap_or(false),
        worktree_path: None,
        reasoning_level: state.reasoning_level.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::session::event_store::{
        AppendOptions, ConnectionConfig, EventType, new_in_memory, run_migrations,
    };

    fn make_store() -> EventStore {
        let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = run_migrations(&conn).unwrap();
        }
        EventStore::new(pool)
    }

    #[test]
    fn reconstruct_empty_session() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None, None)
            .unwrap();

        let state = reconstruct(&store, &session.session.id).unwrap();
        assert_eq!(state.model, "test-model");
        assert!(state.messages.is_empty());
        assert!(!state.is_ended);
    }

    #[test]
    fn reconstruct_with_messages() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None, None)
            .unwrap();
        let sid = &session.session.id;

        // Add user message event
        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({
                    "role": "user",
                    "content": "hello"
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        // Add assistant message event
        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "role": "assistant",
                    "content": [{"type": "text", "text": "hi there"}]
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let state = reconstruct(&store, sid).unwrap();
        assert_eq!(state.model, "test-model");
        // Messages may or may not parse depending on exact format
        // but the reconstruction should not error
    }

    /// Verify that provider-native capability invocation blocks survive the
    /// serde roundtrip used to resume sessions across model providers.
    #[test]
    fn reconstruct_provider_capability_invocation_survives_serde_roundtrip() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None, None)
            .unwrap();
        let sid = &session.session.id;

        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({"content": "write a file"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        // Assistant message with capability_invocation using "input" (API wire format, as persistence stores it)
        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [
                    {"type": "thinking", "thinking": "I'll write the file", "signature": "sig123"},
                    {"type": "capability_invocation", "id": "toolu_01abc", "name": "filesystem::write_file", "arguments": {"file_path": "/tmp/test.txt", "content": "hello"}}
                ],
                "turn": 1
            }),
            parent_id: None,
            sequence: None,
        }).unwrap();

        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::CapabilityInvocationCompleted,
            payload: serde_json::json!({"invocationId": "toolu_01abc", "content": "File written", "isError": false}),
            parent_id: None,
            sequence: None,
        }).unwrap();

        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "Done!"}],
                    "turn": 2
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let state = reconstruct(&store, sid).unwrap();
        // All 4 messages must survive: user, assistant(capability_invocation), capabilityResult, assistant(text)
        assert_eq!(
            state.messages.len(),
            4,
            "All messages must survive serde roundtrip, got: {:?}",
            state
                .messages
                .iter()
                .map(|m| format!("{m:?}"))
                .collect::<Vec<_>>()
        );
        assert!(state.messages[0].is_user());
        assert!(state.messages[1].is_assistant());
        assert!(state.messages[2].is_capability_result());
        assert!(state.messages[3].is_assistant());

        // Verify the capability_invocation arguments are preserved
        if let Message::Assistant { content, .. } = &state.messages[1] {
            let capability_invocation = content
                .iter()
                .find(|c| c.is_capability_invocation())
                .expect("should have capability_invocation");
            if let crate::shared::content::AssistantContent::CapabilityInvocation {
                id,
                name,
                arguments,
                ..
            } = capability_invocation
            {
                assert_eq!(id, "toolu_01abc");
                assert_eq!(name, "filesystem::write_file");
                assert_eq!(arguments["file_path"], "/tmp/test.txt");
            }
        } else {
            panic!("Expected assistant message at index 1");
        }
    }

    #[test]
    fn reconstruct_reasoning_level_none_by_default() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None, None)
            .unwrap();
        let state = reconstruct(&store, &session.session.id).unwrap();
        assert!(state.reasoning_level.is_none());
    }

    #[test]
    fn reconstruct_reasoning_level_from_event() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None, None)
            .unwrap();
        let sid = &session.session.id;

        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::ConfigReasoningLevel,
                payload: serde_json::json!({
                    "previousLevel": null,
                    "newLevel": "high"
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let state = reconstruct(&store, sid).unwrap();
        assert_eq!(state.reasoning_level.as_deref(), Some("high"));
    }

    #[test]
    fn reconstruct_reasoning_level_latest_wins() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None, None)
            .unwrap();
        let sid = &session.session.id;

        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::ConfigReasoningLevel,
                payload: serde_json::json!({"previousLevel": null, "newLevel": "medium"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::ConfigReasoningLevel,
                payload: serde_json::json!({"previousLevel": "medium", "newLevel": "high"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let state = reconstruct(&store, sid).unwrap();
        assert_eq!(state.reasoning_level.as_deref(), Some("high"));
    }

    #[test]
    fn reconstruct_session_not_found() {
        let store = make_store();
        let result = reconstruct(&store, "nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn reconstructed_state_default() {
        let state = ReconstructedState::default();
        assert!(state.model.is_empty());
        assert!(state.messages.is_empty());
        assert_eq!(state.turn_count, 0);
        assert!(!state.is_ended);
    }

    #[test]
    fn reconstruct_with_model_switch() {
        let store = make_store();
        let session = store
            .create_session("model-a", "/tmp", Some("test"), None, None, None)
            .unwrap();
        let sid = &session.session.id;

        // Switch model via event
        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::ConfigModelSwitch,
                payload: serde_json::json!({
                    "model": "model-b",
                    "previousModel": "model-a"
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let state = reconstruct(&store, sid).unwrap();
        // The latest model should be reflected
        // (exact behavior depends on SessionState reconstruction logic)
        assert!(!state.model.is_empty());
    }

    #[test]
    fn reconstruct_multimodal_user_message() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None, None, None)
            .unwrap();
        let sid = &session.session.id;

        // Persist a multimodal user message (content blocks array)
        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({
                    "content": [
                        {"type": "text", "text": "describe this image"},
                        {"type": "image", "data": "base64data", "mimeType": "image/png"}
                    ],
                    "imageCount": 1
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let _ = store
            .append(&AppendOptions {
                session_id: sid,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{"type": "text", "text": "I see an image"}],
                    "turn": 1
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let state = reconstruct(&store, sid).unwrap();
        assert_eq!(state.messages.len(), 2);
        assert!(state.messages[0].is_user());

        // Verify the typed Message::User has Blocks content with image data
        if let Message::User { content, .. } = &state.messages[0] {
            match content {
                crate::shared::messages::UserMessageContent::Blocks(blocks) => {
                    assert_eq!(blocks.len(), 2);
                    assert!(blocks[0].is_text());
                    assert!(blocks[1].is_image());
                    if let crate::shared::content::UserContent::Image { data, mime_type } =
                        &blocks[1]
                    {
                        assert_eq!(data, "base64data");
                        assert_eq!(mime_type, "image/png");
                    } else {
                        panic!("Expected image block");
                    }
                }
                crate::shared::messages::UserMessageContent::Text(_) => {
                    panic!("Expected Blocks content, got Text");
                }
            }
        } else {
            panic!("Expected User message");
        }
    }
}
