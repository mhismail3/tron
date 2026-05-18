use super::enrich_interactive_capability_statuses;
use serde_json::{Value, json};

fn make_capability_invocation(name: &str, id: &str, args: Value) -> Value {
    json!({
        "type": "capability.invocation.started",
        "modelPrimitiveName": name,
        "invocationId": id,
        "payload": {
            "invocationId": id,
            "name": name,
            "arguments": args,
            "turn": 1,
        }
    })
}

fn make_execute_invocation(contract_id: &str, id: &str, payload: Value) -> Value {
    make_capability_invocation(
        "execute",
        id,
        json!({
            "mode": "invoke",
            "contractId": contract_id,
            "payload": payload,
        }),
    )
}

fn make_user_msg(content: &str) -> Value {
    json!({
        "type": "message.user",
        "payload": { "content": content }
    })
}

// ── agent::ask_user ───────────────────────────────────────────────

#[test]
fn answers_single_select() {
    let args = json!({
        "questions": [{"id": "q1", "question": "Color?"}]
    });
    let mut events = vec![
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**Color?**\nAnswer: Red"),
    ];
    enrich_interactive_capability_statuses(&mut events);
    let p = &events[0]["payload"];
    assert_eq!(p["interactionStatus"], "answered");
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
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**Tags?**\nAnswer: bug, urgent, ui"),
    ];
    enrich_interactive_capability_statuses(&mut events);
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
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**Why?**\nAnswer: [Other] custom reason"),
    ];
    enrich_interactive_capability_statuses(&mut events);
    let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
    assert_eq!(parsed["otherValue"], "custom reason");
    assert_eq!(parsed["selectedValues"].as_array().unwrap().len(), 0);
}

#[test]
fn answers_other_value_empty() {
    let args = json!({"questions": [{"id": "q1", "question": "Why?"}]});
    let mut events = vec![
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**Why?**\nAnswer: [Other] "),
    ];
    enrich_interactive_capability_statuses(&mut events);
    let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
    assert!(parsed["otherValue"].is_null());
    assert_eq!(parsed["selectedValues"].as_array().unwrap().len(), 0);
}

#[test]
fn answers_no_selection() {
    let args = json!({"questions": [{"id": "q1", "question": "Skip?"}]});
    let mut events = vec![
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**Skip?**\nAnswer: (no selection)"),
    ];
    enrich_interactive_capability_statuses(&mut events);
    let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
    assert_eq!(parsed["selectedValues"].as_array().unwrap().len(), 0);
    assert!(parsed["otherValue"].is_null());
}

#[test]
fn answers_pending_no_message() {
    let args = json!({"questions": [{"id": "q1", "question": "?"}]});
    let mut events = vec![make_capability_invocation("agent::ask_user", "tc1", args)];
    enrich_interactive_capability_statuses(&mut events);
    assert_eq!(events[0]["payload"]["interactionStatus"], "pending");
    assert!(events[0]["payload"].get("parsedAnswers").is_none());
}

#[test]
fn answers_pending_for_execute_wrapped_ask_user() {
    let payload = json!({"questions": [{"id": "q1", "question": "Proceed?"}]});
    let mut events = vec![make_execute_invocation("agent::ask_user", "tc1", payload)];
    enrich_interactive_capability_statuses(&mut events);
    assert_eq!(events[0]["payload"]["interactionStatus"], "pending");
}

#[test]
fn answers_execute_wrapped_ask_user_payload() {
    let payload = json!({"questions": [{"id": "q1", "question": "Proceed?"}]});
    let mut events = vec![
        make_execute_invocation("agent::ask_user", "tc1", payload),
        make_user_msg("[Answers to your questions]\n\n**Proceed?**\nAnswer: Yes"),
    ];
    enrich_interactive_capability_statuses(&mut events);
    assert_eq!(events[0]["payload"]["interactionStatus"], "answered");
    let parsed = events[0]["payload"]["parsedAnswers"].as_array().unwrap();
    assert_eq!(parsed[0]["questionId"], "q1");
    assert_eq!(parsed[0]["selectedValues"][0], "Yes");
    assert_eq!(events[1]["payload"]["messageKind"], "answered_questions");
}

#[test]
fn answers_superseded_plain_user_message() {
    let args = json!({"questions": [{"id": "q1", "question": "?"}]});
    let mut events = vec![
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("ignore that"),
    ];
    enrich_interactive_capability_statuses(&mut events);
    assert_eq!(events[0]["payload"]["interactionStatus"], "superseded");
}

#[test]
fn answers_question_text_mismatch_dropped() {
    let args = json!({"questions": [{"id": "q1", "question": "Color?"}]});
    let mut events = vec![
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**Different question?**\nAnswer: x"),
    ];
    enrich_interactive_capability_statuses(&mut events);
    // Status is still answered (marker present) but parsedAnswers is empty.
    assert_eq!(events[0]["payload"]["interactionStatus"], "answered");
    assert_eq!(
        events[0]["payload"]["parsedAnswers"]
            .as_array()
            .unwrap()
            .len(),
        0
    );
}

#[test]
fn answers_multiple_questions() {
    let args = json!({"questions": [
        {"id": "q1", "question": "A?"},
        {"id": "q2", "question": "B?"}
    ]});
    let mut events = vec![
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**A?**\nAnswer: yes\n\n**B?**\nAnswer: no"),
    ];
    enrich_interactive_capability_statuses(&mut events);
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
    let mut capability_invocation =
        make_capability_invocation("agent::ask_user", "tc1", Value::Null);
    capability_invocation["payload"]["arguments"] = json!(args_string);
    let mut events = vec![
        capability_invocation,
        make_user_msg("[Answers to your questions]\n\n**Color?**\nAnswer: Red"),
    ];
    enrich_interactive_capability_statuses(&mut events);
    let parsed = events[0]["payload"]["parsedAnswers"][0].clone();
    assert_eq!(parsed["selectedValues"][0], "Red");
}

// ── message.user back-fill ────────────────────────────────────────

#[test]
fn user_message_backfilled_for_answered_questions() {
    let args = json!({"questions": [
        {"id": "q1", "question": "A?"},
        {"id": "q2", "question": "B?"}
    ]});
    let mut events = vec![
        make_capability_invocation("agent::ask_user", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**A?**\nAnswer: yes\n\n**B?**\nAnswer: no"),
    ];
    enrich_interactive_capability_statuses(&mut events);
    let user_payload = &events[1]["payload"];
    assert_eq!(user_payload["messageKind"], "answered_questions");
    assert_eq!(user_payload["answerCount"], 2);
}
