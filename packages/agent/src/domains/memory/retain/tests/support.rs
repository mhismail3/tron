#![allow(unused_imports)]

pub(super) use super::super::events::*;
pub(super) use super::super::parsing::*;
pub(super) use super::super::summarizer::*;
pub(super) use super::super::transcript::*;
pub(super) use super::super::writer::*;
pub(super) use super::super::{
    RetainDeps, RetainSource, emit_auto_retain_triggered, serialize_for_memory,
    trigger_manual_retain, trigger_retain,
};
pub(super) use crate::domains::session::event_store::AppendOptions;
pub(super) use crate::domains::session::event_store::types::EventType;
pub(super) use crate::domains::session::event_store::types::state::Message;
pub(super) use serde_json::{Value, json};
pub(super) use std::sync::Arc;

/// Build an assistant message that emits a `capability_invocation` block for
/// `model_capability_name` with the given id and input payload.
pub(super) fn assistant_capability_invocation_with_input(
    model_capability_name: &str,
    capability_id: &str,
    input: Value,
) -> Message {
    Message {
        role: "assistant".to_string(),
        content: json!([{
            "type": "capability_invocation",
            "id": capability_id,
            "name": model_capability_name,
            "input": input
        }]),
        invocation_id: None,
        is_error: None,
    }
}

pub(super) fn assistant_capability_invocation(
    model_capability_name: &str,
    capability_id: &str,
) -> Message {
    assistant_capability_invocation_with_input(model_capability_name, capability_id, json!({}))
}

pub(super) fn assistant_user_interaction(capability_id: &str, questions: &[&str]) -> Message {
    let qs: Vec<Value> = questions
        .iter()
        .map(|q| {
            json!({
                "question": q,
                "options": [{"label": "A"}, {"label": "B"}],
                "mode": "single"
            })
        })
        .collect();
    assistant_capability_invocation_with_input(
        "agent::ask_user",
        capability_id,
        json!({"questions": qs}),
    )
}

pub(super) fn assistant_text(text: &str) -> Message {
    Message {
        role: "assistant".to_string(),
        content: json!([{"type": "text", "text": text}]),
        invocation_id: None,
        is_error: None,
    }
}

pub(super) fn user_text(text: &str) -> Message {
    Message {
        role: "user".to_string(),
        content: json!(text),
        invocation_id: None,
        is_error: None,
    }
}

pub(super) fn capability_result(invocation_id: &str, text: &str) -> Message {
    Message {
        role: "capability_result".to_string(),
        content: json!([{"type": "text", "text": text}]),
        invocation_id: Some(invocation_id.to_string()),
        is_error: None,
    }
}
