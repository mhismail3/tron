use serde_json::Map;
use serde_json::Value;
use serde_json::json;

/// Derive the structured fields that should be back-filled into the
/// `message.user` payload from the already-parsed capability.invocation.started fields.
pub(super) fn build_user_message_metadata(
    model_capability_id: &str,
    capability_fields: &Map<String, Value>,
) -> Map<String, Value> {
    let mut out = Map::new();
    match model_capability_id {
        "agent::ask_user" => {
            let _ = out.insert("messageKind".into(), json!("answered_questions"));
            if let Some(parsed) = capability_fields
                .get("parsedAnswers")
                .and_then(Value::as_array)
            {
                let _ = out.insert("answerCount".into(), json!(parsed.len()));
            }
        }
        _ => {}
    }
    out
}

/// Find the index of the first `message.user` event strictly after the
/// given index. Returns `None` if none exists (capability invocation is still pending).
pub(super) fn find_first_user_message_after(events: &[Value], from: usize) -> Option<usize> {
    events
        .iter()
        .enumerate()
        .skip(from + 1)
        .find(|(_, e)| e.get("type").and_then(Value::as_str) == Some("message.user"))
        .map(|(i, _)| i)
}

/// Merge the parsed fields into the capability.invocation.started event's `payload` object.
pub(super) fn inject_into_payload(event: &mut Value, fields: Map<String, Value>) {
    let Some(payload) = event.get_mut("payload") else {
        return;
    };
    let Some(obj) = payload.as_object_mut() else {
        return;
    };
    for (k, v) in fields {
        let _ = obj.insert(k, v);
    }
}
