//! Enrich agent::ask_user `capability.invocation.started` events during session reconstruction
//! with their parsed status from subsequent `message.user` events.
//!
//! ## Why server-side
//!
//! iOS used to scan the event stream during reconstruction to figure out
//! whether an agent::ask_user had been answered by parsing text markers like
//! `[Answers to your questions]` that the server emits into synthetic user
//! messages. That logic now lives here so the client reads server-owned
//! structured fields.
//!
//! Since the server generates the answer text prefix in the canonical
//! `agent::submit_answers` engine function, the server is the authoritative
//! source for the parse. Enrichment runs here, injects structured fields into
//! the `capability.invocation.started` wire payload, and iOS just reads them.
//!
//! ## Wire format (what iOS reads)
//!
//! For agent::ask_user, the enriched `payload` gets:
//! - `interactionStatus`: `"pending"` | `"answered"` | `"superseded"`
//! - `parsedAnswers`: array of
//!   `{questionId, selectedValues: [...], otherValue: String?}`
//!
//! In addition, the associated `message.user` event (the one that triggered
//! the enrichment) gets back-filled with the same structured fields that the
//! server writes on the live path via `build_user_event_payload`:
//! - `messageKind`: `"answered_questions"`
//! - `answerCount`
//!
//! This means iOS can render the matching answers chip from historical events
//! without scanning the text content.
//!
//! ## INVARIANT
//!
//! The text formats parsed here must match exactly what
//! `server/domains/agent` generates. If that domain changes the
//! answer prefix format, update this module in lockstep. Tests below pin the
//! exact formats.

use serde_json::Value;

const ANSWERS_MARKER: &str = "[Answers to your questions]";
const SUBAGENT_RESULTS_MARKER: &str = "# Completed Sub-Agent Results";

mod payload;
mod questions;
mod subagent;

#[cfg(test)]
mod tests;

use payload::{build_user_message_metadata, find_first_user_message_after, inject_into_payload};
use questions::{extract_questions, parse_answers};
use subagent::enrich_subagent_result_messages;

const ASK_USER_CONTRACT_ID: &str = "agent::ask_user";

/// Enrich agent::ask_user `capability.invocation.started` events in place.
///
/// Walks the events array, finds each interactive capability invocation, searches for
/// the first subsequent `message.user` event, and injects the parsed status
/// into the capability invocation's `payload` object. Non-interactive capability invocations and
/// all other event types are left untouched.
///
/// The matching `message.user` event also gets back-filled with the same
/// structured `messageKind` + decision/count fields that the live path
/// emits via `build_user_event_payload`.
pub fn enrich_interactive_capability_statuses(events: &mut [Value]) {
    // First pass: collect positions of interactive capability.invocation.started events so we
    // can mutate them afterward without running into borrow-checker issues
    // from simultaneous iteration + mutation.
    let positions: Vec<(usize, String)> = events
        .iter()
        .enumerate()
        .filter_map(|(i, e)| {
            if e.get("type").and_then(Value::as_str)? != "capability.invocation.started" {
                return None;
            }
            let target = capability_target_id(e)?;
            if target == ASK_USER_CONTRACT_ID {
                Some((i, target))
            } else {
                None
            }
        })
        .collect();

    for (call_idx, model_capability_id) in positions {
        let user_msg_position = find_first_user_message_after(events, call_idx);
        let user_msg_content = user_msg_position.map(|idx| {
            events[idx]
                .get("payload")
                .and_then(|p| p.get("content"))
                .and_then(Value::as_str)
                .map(String::from)
                .unwrap_or_default()
        });

        let fields = match model_capability_id.as_str() {
            "agent::ask_user" => {
                let questions = extract_questions(&events[call_idx]);
                parse_answers(user_msg_content.as_deref(), &questions)
            }
            _ => continue,
        };

        // Back-fill the trailing message.user payload with the same
        // structured metadata the live path would emit. Only applies when
        // the marker was actually found (status is approved/denied/answered).
        if let (Some(user_idx), Some(status)) = (
            user_msg_position,
            fields.get("interactionStatus").and_then(Value::as_str),
        ) && status == "answered"
        {
            let user_fields = build_user_message_metadata(model_capability_id.as_str(), &fields);
            inject_into_payload(&mut events[user_idx], user_fields);
        }

        inject_into_payload(&mut events[call_idx], fields);
    }

    // Second pass: back-fill `message.user` events that contain delivered
    // subagent results. The live path tags these with `messageKind` via
    // `PromptRequest.message_metadata`, but historical events from before
    // that change need back-filling so iOS renders a chip.
    enrich_subagent_result_messages(events);
}

fn capability_target_id(event: &Value) -> Option<String> {
    for key in ["contractId", "functionId", "modelPrimitiveName"] {
        if let Some(value) = event.get(key).and_then(Value::as_str)
            && value == ASK_USER_CONTRACT_ID
        {
            return Some(value.to_owned());
        }
    }

    let payload = event.get("payload")?;
    for key in ["contractId", "functionId", "modelPrimitiveName"] {
        if let Some(value) = payload.get(key).and_then(Value::as_str)
            && value == ASK_USER_CONTRACT_ID
        {
            return Some(value.to_owned());
        }
    }

    let args = match payload.get("arguments") {
        Some(Value::String(raw)) => serde_json::from_str::<Value>(raw).ok()?,
        Some(value) => value.clone(),
        None => return None,
    };
    for key in [
        "contractId",
        "capabilityId",
        "functionId",
        "contract_id",
        "capability_id",
        "function_id",
    ] {
        if let Some(value) = args.get(key).and_then(Value::as_str)
            && value == ASK_USER_CONTRACT_ID
        {
            return Some(value.to_owned());
        }
    }
    None
}
