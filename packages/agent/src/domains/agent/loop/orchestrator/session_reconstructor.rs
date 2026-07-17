//! Session reconstructor — rebuild runtime state from event history.
//!
//! Durable provider history is a fail-closed boundary: every reconstructed
//! wire-format message must decode into the runtime [`Message`] model. A bad
//! row is reported with its source event IDs instead of being omitted from the
//! next provider request.

use crate::domains::session::event_store::{EventStore, SessionState};
use crate::shared::protocol::messages::{Message, TokenUsage};

use crate::domains::agent::r#loop::errors::RuntimeError;

/// Reconstructed session state for resuming.
#[derive(Clone, Debug, Default)]
pub(in crate::domains) struct ReconstructedState {
    /// Session model.
    pub(in crate::domains) model: String,
    /// Reconstructed messages.
    pub(in crate::domains) messages: Vec<Message>,
    /// Cumulative token usage.
    pub(in crate::domains) token_usage: TokenUsage,
    /// Turn count.
    pub(in crate::domains) turn_count: u32,
    /// Working directory.
    pub(in crate::domains) working_directory: Option<String>,
    /// Whether the session has ended.
    pub(in crate::domains) is_ended: bool,
}

/// Reconstruct session state from the event store.
pub(in crate::domains::agent::r#loop) fn reconstruct(
    event_store: &EventStore,
    session_id: &str,
) -> Result<ReconstructedState, RuntimeError> {
    let state = event_store
        .get_state_at_head(session_id)
        .map_err(|e| RuntimeError::Persistence(e.to_string()))?;

    from_session_state(&state)
}

/// Convert `SessionState` to `ReconstructedState`.
#[allow(clippy::cast_sign_loss)]
fn from_session_state(state: &SessionState) -> Result<ReconstructedState, RuntimeError> {
    let messages: Vec<Message> = state
        .messages_with_event_ids
        .iter()
        .map(|message| {
            let source = format!(
                "event IDs {:?}, role '{}'",
                message.event_ids, message.message.role
            );
            let value = serde_json::to_value(&message.message).map_err(|error| {
                RuntimeError::Persistence(format!(
                    "failed to serialize reconstructed message from {source}: {error}"
                ))
            })?;
            serde_json::from_value::<Message>(value).map_err(|error| {
                RuntimeError::Persistence(format!(
                    "failed to decode reconstructed message from {source}: {error}"
                ))
            })
        })
        .collect::<Result<_, _>>()?;

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

    let turn_count = u32::try_from(state.turn_count).map_err(|_| {
        RuntimeError::Persistence(format!(
            "invalid reconstructed turn count {}",
            state.turn_count
        ))
    })?;

    Ok(ReconstructedState {
        model: state.model.clone(),
        messages,
        token_usage,
        turn_count,
        working_directory: Some(state.working_directory.clone()),
        is_ended: state.is_ended.unwrap_or(false),
    })
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
            .create_session("test-model", "/tmp", Some("test"), None)
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
            .create_session("test-model", "/tmp", Some("test"), None)
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
        assert_eq!(state.messages.len(), 2);
    }

    #[test]
    fn reconstruct_rejects_structurally_invalid_persisted_message() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();
        let malformed = store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": "assistant content must be an array of blocks",
                    "turn": 1
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let error = reconstruct(&store, &session.session.id)
            .expect_err("malformed durable provider history must fail closed");
        let message = error.to_string();
        assert!(message.contains("failed to decode reconstructed message"));
        assert!(message.contains(&malformed.id));
        assert!(message.contains("role 'assistant'"));
    }

    #[test]
    fn reconstruct_rejects_malformed_persisted_capability_completion() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();
        let malformed = store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::CapabilityInvocationCompleted,
                payload: serde_json::json!({"content": "output", "isError": false}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let error = reconstruct(&store, &session.session.id)
            .expect_err("malformed durable capability history must fail closed");
        let message = error.to_string();
        assert!(message.contains(&malformed.id));
        assert!(message.contains("invocationId"));
    }

    #[test]
    fn reconstruct_rejects_turn_count_beyond_runtime_ordinal_range() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap();
        store
            .append(&AppendOptions {
                session_id: &session.session.id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "role": "assistant",
                    "content": [{"type": "text", "text": "legacy overflow"}],
                    "turn": i64::from(u32::MAX) + 1,
                    "model": "test-model",
                    "stopReason": "end_turn"
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let error = reconstruct(&store, &session.session.id)
            .expect_err("oversized durable turn must fail closed");
        assert!(
            error
                .to_string()
                .contains("invalid reconstructed turn count")
        );
    }

    /// Verify that provider-native capability invocation blocks survive the
    /// serde roundtrip used to resume sessions across model providers.
    #[test]
    fn reconstruct_provider_capability_invocation_survives_serde_roundtrip() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
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
                    {"type": "capability_invocation", "id": "toolu_01abc", "name": "execute", "arguments": {"operation": "file_write", "path": "/tmp/test.txt", "content": "hello"}}
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
            if let crate::shared::protocol::content::AssistantContent::CapabilityInvocation {
                id,
                name,
                arguments,
                ..
            } = capability_invocation
            {
                assert_eq!(id, "toolu_01abc");
                assert_eq!(name, "execute");
                assert_eq!(arguments["operation"], "file_write");
                assert_eq!(arguments["path"], "/tmp/test.txt");
            }
        } else {
            panic!("Expected assistant message at index 1");
        }
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
    fn reconstruct_multimodal_user_message() {
        let store = make_store();
        let session = store
            .create_session("test-model", "/tmp", Some("test"), None)
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
                crate::shared::protocol::messages::UserMessageContent::Blocks(blocks) => {
                    assert_eq!(blocks.len(), 2);
                    assert!(blocks[0].is_text());
                    assert!(blocks[1].is_image());
                    if let crate::shared::protocol::content::UserContent::Image {
                        data,
                        mime_type,
                    } = &blocks[1]
                    {
                        assert_eq!(data, "base64data");
                        assert_eq!(mime_type, "image/png");
                    } else {
                        panic!("Expected image block");
                    }
                }
                crate::shared::protocol::messages::UserMessageContent::Text(_) => {
                    panic!("Expected Blocks content, got Text");
                }
            }
        } else {
            panic!("Expected User message");
        }
    }
}
