//! Enrich interactive tool (GetConfirmation, AskUserQuestion) `tool.call`
//! events during session reconstruction with their parsed status from
//! subsequent `message.user` events.
//!
//! ## Why server-side
//!
//! Historically, iOS scanned the event stream during reconstruction to
//! figure out whether a GetConfirmation had been approved/denied or whether
//! an AskUserQuestion had been answered — by parsing text markers like
//! `[Confirmation response]` or `[Answers to your questions]` that the
//! server emits into synthetic user messages. That logic lived in
//! `GetConfirmationDetector`, `AskUserQuestionDetector`, and `AnswerParser`
//! on iOS (~270 lines total).
//!
//! Since the server generates those text prefixes in
//! `handlers/agent_confirmation.rs`, the server is the authoritative source
//! for the parse. Enrichment runs here, injects structured fields into the
//! `tool.call` wire payload, and iOS just reads them — no scanning, no
//! fragile string matching on the client.
//!
//! ## Wire format (what iOS reads)
//!
//! For GetConfirmation, the enriched `payload` gets:
//! - `toolStatus`: `"pending"` | `"approved"` | `"denied"` | `"superseded"`
//! - `confirmationDecision`: `"Approved"` | `"Denied"` (when present)
//! - `confirmationNote`: optional note text (when present and non-empty)
//!
//! For AskUserQuestion, the enriched `payload` gets:
//! - `toolStatus`: `"pending"` | `"answered"` | `"superseded"`
//! - `parsedAnswers`: array of
//!   `{questionId, selectedValues: [...], otherValue: String?}`
//!
//! ## INVARIANT
//!
//! The text formats parsed here must match exactly what
//! `server/rpc/handlers/agent_confirmation.rs` generates. If that file
//! changes the confirmation/answer prefix format, update this module in
//! lockstep. Tests below pin the exact formats.

use serde_json::{Map, Value, json};

const CONFIRMATION_MARKER: &str = "[Confirmation response]";
const ANSWERS_MARKER: &str = "[Answers to your questions]";

/// Enrich GetConfirmation and AskUserQuestion `tool.call` events in place.
///
/// Walks the events array, finds each interactive tool call, searches for
/// the first subsequent `message.user` event, and injects the parsed status
/// into the tool call's `payload` object. Non-interactive tool calls and
/// all other event types are left untouched.
pub fn enrich_interactive_tool_statuses(events: &mut [Value]) {
    // First pass: collect positions of interactive tool.call events so we
    // can mutate them afterward without running into borrow-checker issues
    // from simultaneous iteration + mutation.
    let positions: Vec<(usize, String)> = events
        .iter()
        .enumerate()
        .filter_map(|(i, e)| {
            if e.get("type").and_then(Value::as_str)? != "tool.call" {
                return None;
            }
            let name = e.get("toolName").and_then(Value::as_str)?.to_string();
            if name == "GetConfirmation" || name == "AskUserQuestion" {
                Some((i, name))
            } else {
                None
            }
        })
        .collect();

    for (call_idx, tool_name) in positions {
        let user_msg = find_first_user_message_after(events, call_idx);
        let fields = match tool_name.as_str() {
            "GetConfirmation" => parse_confirmation(user_msg.as_deref()),
            "AskUserQuestion" => {
                let questions = extract_questions(&events[call_idx]);
                parse_answers(user_msg.as_deref(), &questions)
            }
            _ => continue,
        };
        inject_into_payload(&mut events[call_idx], fields);
    }
}

/// Find the `content` of the first `message.user` event strictly after the
/// given index. Returns `None` if none exists (tool call is still pending).
fn find_first_user_message_after(events: &[Value], from: usize) -> Option<String> {
    events
        .iter()
        .skip(from + 1)
        .find(|e| e.get("type").and_then(Value::as_str) == Some("message.user"))
        .and_then(|e| e.get("payload"))
        .and_then(|p| p.get("content"))
        .and_then(Value::as_str)
        .map(String::from)
}

/// Parse a `[Confirmation response]`-prefixed user message into
/// `{toolStatus, confirmationDecision, confirmationNote}`.
///
/// Matches the iOS `GetConfirmationDetector.parseConfirmationResponse`
/// semantics exactly, including:
/// - case-sensitive `Decision: Approved` check
/// - unparseable decisions default to `denied`
/// - empty `Note:` is treated as absent
fn parse_confirmation(user_msg: Option<&str>) -> Map<String, Value> {
    let mut out = Map::new();
    let Some(msg) = user_msg else {
        let _ = out.insert("toolStatus".into(), json!("pending"));
        return out;
    };
    if !msg.contains(CONFIRMATION_MARKER) {
        let _ = out.insert("toolStatus".into(), json!("superseded"));
        return out;
    }

    let mut decision: Option<String> = None;
    let mut note: Option<String> = None;
    for raw_line in msg.lines() {
        let line = raw_line.trim();
        if let Some(rest) = line.strip_prefix("Decision:") {
            decision = Some(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("Note:") {
            let trimmed = rest.trim();
            if !trimmed.is_empty() {
                note = Some(trimmed.to_string());
            }
        }
    }

    let status = match decision.as_deref() {
        Some("Approved") => "approved",
        _ => "denied",
    };
    let _ = out.insert("toolStatus".into(), json!(status));
    if let Some(d) = decision {
        let _ = out.insert("confirmationDecision".into(), json!(d));
    }
    if let Some(n) = note {
        let _ = out.insert("confirmationNote".into(), json!(n));
    }
    out
}

/// Extract the list of `(questionId, questionText)` pairs from an
/// AskUserQuestion tool.call event's payload arguments.
fn extract_questions(tool_call_event: &Value) -> Vec<(String, String)> {
    let Some(payload) = tool_call_event.get("payload") else {
        return vec![];
    };
    let parsed = match payload.get("arguments") {
        Some(Value::String(s)) => serde_json::from_str::<Value>(s).unwrap_or(Value::Null),
        Some(v) => v.clone(),
        None => return vec![],
    };
    parsed
        .get("questions")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|q| {
                    let id = q.get("id").and_then(Value::as_str)?.to_string();
                    let text = q.get("question").and_then(Value::as_str)?.to_string();
                    Some((id, text))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Parse an `[Answers to your questions]`-prefixed user message into
/// `{toolStatus, parsedAnswers: [...]}`.
///
/// Matches the iOS `AnswerParser.parseAnswers` semantics exactly, including:
/// - question text matched by exact string equality against the original
/// - `[Other] value` → `otherValue` path
/// - `(no selection)` → empty selectedValues, nil otherValue
/// - comma-space split (`", "`) for multi-select values
/// - questions that fail to match the original params list are dropped
fn parse_answers(
    user_msg: Option<&str>,
    questions: &[(String, String)],
) -> Map<String, Value> {
    let mut out = Map::new();
    let Some(msg) = user_msg else {
        let _ = out.insert("toolStatus".into(), json!("pending"));
        return out;
    };
    if !msg.contains(ANSWERS_MARKER) {
        let _ = out.insert("toolStatus".into(), json!("superseded"));
        return out;
    }

    let mut parsed: Vec<Value> = Vec::new();
    let mut current_question: Option<String> = None;
    let mut current_answer: Option<String> = None;

    let flush = |current_question: &mut Option<String>,
                 current_answer: &mut Option<String>,
                 parsed: &mut Vec<Value>| {
        if let (Some(q_text), Some(a_line)) = (current_question.take(), current_answer.take())
            && let Some((q_id, _)) = questions.iter().find(|(_id, text)| text == &q_text)
        {
            parsed.push(build_answer(&a_line, q_id));
        }
    };

    for raw_line in msg.lines() {
        let line = raw_line.trim();
        if line.starts_with("**") && line.ends_with("**") && line.len() > 4 {
            // New question starts — flush any pending question first.
            flush(&mut current_question, &mut current_answer, &mut parsed);
            current_question = Some(line[2..line.len() - 2].to_string());
        } else if let Some(rest) = line.strip_prefix("Answer:") {
            current_answer = Some(rest.trim().to_string());
        }
    }
    flush(&mut current_question, &mut current_answer, &mut parsed);

    let _ = out.insert("toolStatus".into(), json!("answered"));
    let _ = out.insert("parsedAnswers".into(), Value::Array(parsed));
    out
}

fn build_answer(answer_line: &str, question_id: &str) -> Value {
    if answer_line == "(no selection)" {
        return json!({
            "questionId": question_id,
            "selectedValues": [],
            "otherValue": Value::Null,
        });
    }
    if let Some(rest) = answer_line.strip_prefix("[Other]") {
        let trimmed = rest.trim();
        let other_value = if trimmed.is_empty() {
            Value::Null
        } else {
            Value::String(trimmed.to_string())
        };
        return json!({
            "questionId": question_id,
            "selectedValues": [],
            "otherValue": other_value,
        });
    }
    let values: Vec<&str> = answer_line.split(", ").collect();
    json!({
        "questionId": question_id,
        "selectedValues": values,
        "otherValue": Value::Null,
    })
}

/// Merge the parsed fields into the tool.call event's `payload` object.
fn inject_into_payload(event: &mut Value, fields: Map<String, Value>) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn make_tool_call(name: &str, id: &str, args: Value) -> Value {
        json!({
            "type": "tool.call",
            "toolName": name,
            "toolCallId": id,
            "payload": {
                "toolCallId": id,
                "name": name,
                "arguments": args,
                "turn": 1,
            }
        })
    }

    fn make_user_msg(content: &str) -> Value {
        json!({
            "type": "message.user",
            "payload": { "content": content }
        })
    }

    // ── GetConfirmation ───────────────────────────────────────────────

    #[test]
    fn confirmation_approved_with_note() {
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({"action": "delete file"})),
            make_user_msg("[Confirmation response]\n\nAction: delete file\nDecision: Approved\nNote: go ahead"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let p = &events[0]["payload"];
        assert_eq!(p["toolStatus"], "approved");
        assert_eq!(p["confirmationDecision"], "Approved");
        assert_eq!(p["confirmationNote"], "go ahead");
    }

    #[test]
    fn confirmation_denied_no_note() {
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({})),
            make_user_msg("[Confirmation response]\n\nAction: x\nDecision: Denied"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let p = &events[0]["payload"];
        assert_eq!(p["toolStatus"], "denied");
        assert_eq!(p["confirmationDecision"], "Denied");
        assert!(p.get("confirmationNote").is_none());
    }

    #[test]
    fn confirmation_denied_with_note() {
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({})),
            make_user_msg("[Confirmation response]\n\nDecision: Denied\nNote: no thanks"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let p = &events[0]["payload"];
        assert_eq!(p["toolStatus"], "denied");
        assert_eq!(p["confirmationNote"], "no thanks");
    }

    #[test]
    fn confirmation_pending_no_user_message() {
        let mut events = vec![make_tool_call("GetConfirmation", "tc1", json!({}))];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "pending");
        assert!(events[0]["payload"].get("confirmationDecision").is_none());
    }

    #[test]
    fn confirmation_superseded_user_typed_other() {
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({})),
            make_user_msg("nevermind, do something else"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "superseded");
    }

    #[test]
    fn confirmation_decision_case_sensitive() {
        // Matches iOS: "approved" (lowercase) does not match enum rawValue → denied.
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({})),
            make_user_msg("[Confirmation response]\n\nDecision: approved"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "denied");
    }

    #[test]
    fn confirmation_empty_note_omitted() {
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({})),
            make_user_msg("[Confirmation response]\n\nDecision: Approved\nNote:"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "approved");
        assert!(events[0]["payload"].get("confirmationNote").is_none());
    }

    #[test]
    fn confirmation_extra_whitespace_in_values() {
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({})),
            make_user_msg("[Confirmation response]\n\nDecision:   Approved  \nNote:   trim me  "),
        ];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "approved");
        assert_eq!(events[0]["payload"]["confirmationNote"], "trim me");
    }

    // ── AskUserQuestion ───────────────────────────────────────────────

    #[test]
    fn answers_single_select() {
        let args = json!({
            "questions": [{"id": "q1", "question": "Color?"}]
        });
        let mut events = vec![
            make_tool_call("AskUserQuestion", "tc1", args),
            make_user_msg("[Answers to your questions]\n\n**Color?**\nAnswer: Red"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let p = &events[0]["payload"];
        assert_eq!(p["toolStatus"], "answered");
        let parsed = p["parsedAnswers"].as_array().unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0]["questionId"], "q1");
        assert_eq!(parsed[0]["selectedValues"][0], "Red");
        assert!(parsed[0]["otherValue"].is_null());
    }

    #[test]
    fn answers_multi_select() {
        let args = json!({"questions": [{"id": "q1", "question": "Tags?"}]});
        let mut events = vec![
            make_tool_call("AskUserQuestion", "tc1", args),
            make_user_msg("[Answers to your questions]\n\n**Tags?**\nAnswer: bug, urgent, ui"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
        let values = parsed["selectedValues"].as_array().unwrap();
        assert_eq!(values.len(), 3);
        assert_eq!(values[0], "bug");
        assert_eq!(values[1], "urgent");
        assert_eq!(values[2], "ui");
    }

    #[test]
    fn answers_other_value() {
        let args = json!({"questions": [{"id": "q1", "question": "Why?"}]});
        let mut events = vec![
            make_tool_call("AskUserQuestion", "tc1", args),
            make_user_msg(
                "[Answers to your questions]\n\n**Why?**\nAnswer: [Other] custom reason",
            ),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
        assert_eq!(parsed["otherValue"], "custom reason");
        assert_eq!(parsed["selectedValues"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn answers_other_value_empty() {
        let args = json!({"questions": [{"id": "q1", "question": "Why?"}]});
        let mut events = vec![
            make_tool_call("AskUserQuestion", "tc1", args),
            make_user_msg("[Answers to your questions]\n\n**Why?**\nAnswer: [Other] "),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
        assert!(parsed["otherValue"].is_null());
        assert_eq!(parsed["selectedValues"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn answers_no_selection() {
        let args = json!({"questions": [{"id": "q1", "question": "Skip?"}]});
        let mut events = vec![
            make_tool_call("AskUserQuestion", "tc1", args),
            make_user_msg("[Answers to your questions]\n\n**Skip?**\nAnswer: (no selection)"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
        assert_eq!(parsed["selectedValues"].as_array().unwrap().len(), 0);
        assert!(parsed["otherValue"].is_null());
    }

    #[test]
    fn answers_pending_no_message() {
        let args = json!({"questions": [{"id": "q1", "question": "?"}]});
        let mut events = vec![make_tool_call("AskUserQuestion", "tc1", args)];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "pending");
        assert!(events[0]["payload"].get("parsedAnswers").is_none());
    }

    #[test]
    fn answers_superseded_plain_user_message() {
        let args = json!({"questions": [{"id": "q1", "question": "?"}]});
        let mut events = vec![
            make_tool_call("AskUserQuestion", "tc1", args),
            make_user_msg("ignore that"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "superseded");
    }

    #[test]
    fn answers_question_text_mismatch_dropped() {
        let args = json!({"questions": [{"id": "q1", "question": "Color?"}]});
        let mut events = vec![
            make_tool_call("AskUserQuestion", "tc1", args),
            make_user_msg(
                "[Answers to your questions]\n\n**Different question?**\nAnswer: x",
            ),
        ];
        enrich_interactive_tool_statuses(&mut events);
        // Status is still answered (marker present) but parsedAnswers is empty.
        assert_eq!(events[0]["payload"]["toolStatus"], "answered");
        assert_eq!(events[0]["payload"]["parsedAnswers"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn answers_multiple_questions() {
        let args = json!({"questions": [
            {"id": "q1", "question": "A?"},
            {"id": "q2", "question": "B?"}
        ]});
        let mut events = vec![
            make_tool_call("AskUserQuestion", "tc1", args),
            make_user_msg("[Answers to your questions]\n\n**A?**\nAnswer: yes\n\n**B?**\nAnswer: no"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let parsed = events[0]["payload"]["parsedAnswers"].as_array().unwrap();
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0]["questionId"], "q1");
        assert_eq!(parsed[0]["selectedValues"][0], "yes");
        assert_eq!(parsed[1]["questionId"], "q2");
        assert_eq!(parsed[1]["selectedValues"][0], "no");
    }

    #[test]
    fn answers_arguments_as_json_string() {
        // Some code paths serialize arguments to a string before persist.
        // Enrichment must handle both shapes.
        let args_string = serde_json::to_string(&json!({
            "questions": [{"id": "q1", "question": "Color?"}]
        }))
        .unwrap();
        let mut tool_call = make_tool_call("AskUserQuestion", "tc1", Value::Null);
        tool_call["payload"]["arguments"] = json!(args_string);
        let mut events = vec![
            tool_call,
            make_user_msg("[Answers to your questions]\n\n**Color?**\nAnswer: Red"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
        assert_eq!(parsed["selectedValues"][0], "Red");
    }

    // ── Cross-cutting ─────────────────────────────────────────────────

    #[test]
    fn multiple_interactive_tools_independent() {
        let args = json!({"questions": [{"id": "q1", "question": "?"}]});
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({})),
            make_user_msg("[Confirmation response]\n\nDecision: Approved"),
            make_tool_call("AskUserQuestion", "tc2", args),
            make_user_msg("[Answers to your questions]\n\n**?**\nAnswer: ok"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "approved");
        assert_eq!(events[2]["payload"]["toolStatus"], "answered");
    }

    #[test]
    fn non_interactive_tools_unchanged() {
        let mut events = vec![
            make_tool_call("Bash", "tc1", json!({"command": "ls"})),
            make_user_msg("ok"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        assert!(events[0]["payload"].get("toolStatus").is_none());
    }

    #[test]
    fn enrichment_preserves_existing_payload_fields() {
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({"action": "X"})),
            make_user_msg("[Confirmation response]\n\nDecision: Approved"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        let p = &events[0]["payload"];
        assert_eq!(p["toolCallId"], "tc1");
        assert_eq!(p["name"], "GetConfirmation");
        assert_eq!(p["turn"], 1);
    }

    #[test]
    fn empty_events_array_is_noop() {
        let mut events: Vec<Value> = vec![];
        enrich_interactive_tool_statuses(&mut events);
    }

    #[test]
    fn tool_call_at_end_is_pending() {
        let mut events = vec![
            make_user_msg("unrelated"),
            make_tool_call("GetConfirmation", "tc1", json!({})),
        ];
        enrich_interactive_tool_statuses(&mut events);
        // message.user is BEFORE the tool.call, not after — so pending.
        assert_eq!(events[1]["payload"]["toolStatus"], "pending");
    }

    #[test]
    fn first_matching_user_message_wins() {
        let mut events = vec![
            make_tool_call("GetConfirmation", "tc1", json!({})),
            make_user_msg("[Confirmation response]\n\nDecision: Approved"),
            make_user_msg("[Confirmation response]\n\nDecision: Denied"),
        ];
        enrich_interactive_tool_statuses(&mut events);
        assert_eq!(events[0]["payload"]["toolStatus"], "approved");
    }
}
