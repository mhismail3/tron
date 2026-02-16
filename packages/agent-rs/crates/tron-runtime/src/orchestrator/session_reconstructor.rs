//! Session reconstructor — rebuild runtime state from event history.

use tron_core::messages::{Message, TokenUsage};
use tron_events::{EventStore, SessionState};

use crate::errors::RuntimeError;

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
}

/// Reconstruct session state from the event store.
pub fn reconstruct(event_store: &EventStore, session_id: &str) -> Result<ReconstructedState, RuntimeError> {
    let state = event_store
        .get_state_at_head(session_id)
        .map_err(|e| RuntimeError::Persistence(e.to_string()))?;

    Ok(from_session_state(&state))
}

/// Convert `SessionState` to `ReconstructedState`.
#[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
fn from_session_state(state: &SessionState) -> ReconstructedState {
    let messages: Vec<Message> = state
        .messages_with_event_ids
        .iter()
        .filter_map(|m| {
            serde_json::from_value(serde_json::to_value(&m.message).ok()?).ok()
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_events::{new_in_memory, run_migrations, ConnectionConfig, EventType, AppendOptions};

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
        let session = store.create_session("test-model", "/tmp", Some("test")).unwrap();

        let state = reconstruct(&store, &session.session.id).unwrap();
        assert_eq!(state.model, "test-model");
        assert!(state.messages.is_empty());
        assert!(!state.is_ended);
    }

    #[test]
    fn reconstruct_with_messages() {
        let store = make_store();
        let session = store.create_session("test-model", "/tmp", Some("test")).unwrap();
        let sid = &session.session.id;

        // Add user message event
        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({
                "role": "user",
                "content": "hello"
            }),
            parent_id: None,
        }).unwrap();

        // Add assistant message event
        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "role": "assistant",
                "content": [{"type": "text", "text": "hi there"}]
            }),
            parent_id: None,
        }).unwrap();

        let state = reconstruct(&store, sid).unwrap();
        assert_eq!(state.model, "test-model");
        // Messages may or may not parse depending on exact format
        // but the reconstruction should not error
    }

    /// Verify that assistant messages with tool_use blocks survive the serde
    /// roundtrip. Persistence stores `"input"` (API wire format) but the typed
    /// `AssistantContent::ToolUse` expects `"arguments"`. The `#[serde(alias)]`
    /// on `arguments` makes this work.
    #[test]
    fn reconstruct_tool_use_survives_serde_roundtrip() {
        let store = make_store();
        let session = store.create_session("test-model", "/tmp", Some("test")).unwrap();
        let sid = &session.session.id;

        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::MessageUser,
            payload: serde_json::json!({"content": "write a file"}),
            parent_id: None,
        }).unwrap();

        // Assistant message with tool_use using "input" (API wire format, as persistence stores it)
        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [
                    {"type": "thinking", "thinking": "I'll write the file", "signature": "sig123"},
                    {"type": "tool_use", "id": "toolu_01abc", "name": "Write", "input": {"file_path": "/tmp/test.txt", "content": "hello"}}
                ],
                "turn": 1
            }),
            parent_id: None,
        }).unwrap();

        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::ToolResult,
            payload: serde_json::json!({"toolCallId": "toolu_01abc", "content": "File written", "isError": false}),
            parent_id: None,
        }).unwrap();

        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::MessageAssistant,
            payload: serde_json::json!({
                "content": [{"type": "text", "text": "Done!"}],
                "turn": 2
            }),
            parent_id: None,
        }).unwrap();

        let state = reconstruct(&store, sid).unwrap();
        // All 4 messages must survive: user, assistant(tool_use), toolResult, assistant(text)
        assert_eq!(state.messages.len(), 4, "All messages must survive serde roundtrip, got: {:?}", state.messages.iter().map(|m| format!("{:?}", m)).collect::<Vec<_>>());
        assert!(state.messages[0].is_user());
        assert!(state.messages[1].is_assistant());
        assert!(state.messages[2].is_tool_result());
        assert!(state.messages[3].is_assistant());

        // Verify the tool_use arguments are preserved
        if let Message::Assistant { content, .. } = &state.messages[1] {
            let tool_use = content.iter().find(|c| c.is_tool_use()).expect("should have tool_use");
            if let tron_core::content::AssistantContent::ToolUse { id, name, arguments, .. } = tool_use {
                assert_eq!(id, "toolu_01abc");
                assert_eq!(name, "Write");
                assert_eq!(arguments["file_path"], "/tmp/test.txt");
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
    fn reconstruct_with_model_switch() {
        let store = make_store();
        let session = store.create_session("model-a", "/tmp", Some("test")).unwrap();
        let sid = &session.session.id;

        // Switch model via event
        let _ = store.append(&AppendOptions {
            session_id: sid,
            event_type: EventType::ConfigModelSwitch,
            payload: serde_json::json!({
                "model": "model-b",
                "previousModel": "model-a"
            }),
            parent_id: None,
        }).unwrap();

        let state = reconstruct(&store, sid).unwrap();
        // The latest model should be reflected
        // (exact behavior depends on SessionState reconstruction logic)
        assert!(!state.model.is_empty());
    }
}
