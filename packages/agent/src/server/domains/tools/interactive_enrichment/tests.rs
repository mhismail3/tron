use super::*;
use serde_json::{Value, json};

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
        make_user_msg(
            "[Confirmation response]\n\nAction: delete file\nDecision: Approved\nNote: go ahead",
        ),
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
        make_user_msg("[Answers to your questions]\n\n**Why?**\nAnswer: [Other] custom reason"),
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
        make_user_msg("[Answers to your questions]\n\n**Different question?**\nAnswer: x"),
    ];
    enrich_interactive_tool_statuses(&mut events);
    // Status is still answered (marker present) but parsedAnswers is empty.
    assert_eq!(events[0]["payload"]["toolStatus"], "answered");
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

// ── message.user back-fill ────────────────────────────────────────

#[test]
fn user_message_backfilled_for_confirmation_approved() {
    let mut events = vec![
        make_tool_call("GetConfirmation", "tc1", json!({})),
        make_user_msg("[Confirmation response]\n\nDecision: Approved\nNote: looks good"),
    ];
    enrich_interactive_tool_statuses(&mut events);
    let user_payload = &events[1]["payload"];
    assert_eq!(user_payload["messageKind"], "confirmation_response");
    assert_eq!(user_payload["confirmationDecision"], "Approved");
    assert_eq!(user_payload["confirmationNote"], "looks good");
}

#[test]
fn user_message_backfilled_for_confirmation_denied_without_note() {
    let mut events = vec![
        make_tool_call("GetConfirmation", "tc1", json!({})),
        make_user_msg("[Confirmation response]\n\nDecision: Denied"),
    ];
    enrich_interactive_tool_statuses(&mut events);
    let user_payload = &events[1]["payload"];
    assert_eq!(user_payload["messageKind"], "confirmation_response");
    assert_eq!(user_payload["confirmationDecision"], "Denied");
    assert!(user_payload.get("confirmationNote").is_none());
}

#[test]
fn user_message_backfilled_for_answered_questions() {
    let args = json!({"questions": [
        {"id": "q1", "question": "A?"},
        {"id": "q2", "question": "B?"}
    ]});
    let mut events = vec![
        make_tool_call("AskUserQuestion", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**A?**\nAnswer: yes\n\n**B?**\nAnswer: no"),
    ];
    enrich_interactive_tool_statuses(&mut events);
    let user_payload = &events[1]["payload"];
    assert_eq!(user_payload["messageKind"], "answered_questions");
    assert_eq!(user_payload["answerCount"], 2);
}

#[test]
fn user_message_not_backfilled_when_superseded() {
    let mut events = vec![
        make_tool_call("GetConfirmation", "tc1", json!({})),
        make_user_msg("nevermind, something else"),
    ];
    enrich_interactive_tool_statuses(&mut events);
    let user_payload = &events[1]["payload"];
    // Superseded user messages are plain text — no messageKind injected.
    assert!(user_payload.get("messageKind").is_none());
    assert_eq!(events[0]["payload"]["toolStatus"], "superseded");
}

#[test]
fn user_message_not_backfilled_when_pending() {
    // Tool.call present, no user message after — nothing to back-fill.
    let mut events = vec![make_tool_call("GetConfirmation", "tc1", json!({}))];
    enrich_interactive_tool_statuses(&mut events);
    assert_eq!(events[0]["payload"]["toolStatus"], "pending");
}

#[test]
fn user_message_backfill_preserves_content() {
    let mut events = vec![
        make_tool_call("GetConfirmation", "tc1", json!({})),
        make_user_msg("[Confirmation response]\n\nDecision: Approved"),
    ];
    enrich_interactive_tool_statuses(&mut events);
    let content = events[1]["payload"]["content"].as_str().unwrap();
    assert!(content.contains("Approved"));
}

#[test]
fn user_message_backfill_for_answered_questions_empty_parsed() {
    // When the answer text doesn't match any known question, parsedAnswers
    // is empty but toolStatus is still "answered". The user message should
    // still be back-filled with messageKind=answered_questions and
    // answerCount=0.
    let args = json!({"questions": [{"id": "q1", "question": "Color?"}]});
    let mut events = vec![
        make_tool_call("AskUserQuestion", "tc1", args),
        make_user_msg("[Answers to your questions]\n\n**Different?**\nAnswer: x"),
    ];
    enrich_interactive_tool_statuses(&mut events);
    let user_payload = &events[1]["payload"];
    assert_eq!(user_payload["messageKind"], "answered_questions");
    assert_eq!(user_payload["answerCount"], 0);
}

// ── Subagent results back-fill ──────────────────────────────────────

fn make_subagent_results_content(agents: &[(&str, bool)]) -> String {
    let mut s = String::from(
        "# Completed Sub-Agent Results\n\n\
        The following sub-agent(s) have completed since your last turn. \
        Review their results and incorporate them into your response.\n\n",
    );
    for (id, success) in agents {
        let icon = if *success { "+" } else { "x" };
        s.push_str(&format!(
            "## [{icon}] Sub-Agent: `{id}`\n\n\
             **Task**: test task\n\
             **Status**: {}\n\
             **Turns**: 2\n\
             **Duration**: 5.0s\n\n\
             **Output**:\n```\ndone\n```\n\n---\n\n",
            if *success { "Completed" } else { "Failed" }
        ));
    }
    s
}

#[test]
fn subagent_results_message_gets_backfilled() {
    let content = make_subagent_results_content(&[("sub-1", true)]);
    let mut events = vec![make_user_msg(&content)];
    enrich_interactive_tool_statuses(&mut events);
    let p = &events[0]["payload"];
    assert_eq!(p["messageKind"], "subagent_results_delivered");
    assert_eq!(p["subagentCount"], 1);
}

#[test]
fn subagent_results_multiple_agents_correct_count() {
    let content =
        make_subagent_results_content(&[("sub-1", true), ("sub-2", true), ("sub-3", true)]);
    let mut events = vec![make_user_msg(&content)];
    enrich_interactive_tool_statuses(&mut events);
    assert_eq!(events[0]["payload"]["subagentCount"], 3);
}

#[test]
fn subagent_results_mixed_success_failure_counted() {
    let content = make_subagent_results_content(&[("sub-1", true), ("sub-2", false)]);
    let mut events = vec![make_user_msg(&content)];
    enrich_interactive_tool_statuses(&mut events);
    assert_eq!(events[0]["payload"]["subagentCount"], 2);
}

#[test]
fn subagent_results_already_tagged_not_overwritten() {
    let content = make_subagent_results_content(&[("sub-1", true)]);
    let mut events = vec![json!({
        "type": "message.user",
        "payload": {
            "content": content,
            "messageKind": "subagent_results_delivered",
            "subagentCount": 42,
        }
    })];
    enrich_interactive_tool_statuses(&mut events);
    // Should not overwrite the existing count
    assert_eq!(events[0]["payload"]["subagentCount"], 42);
}

#[test]
fn subagent_results_array_content_skipped() {
    let content = make_subagent_results_content(&[("sub-1", true)]);
    let mut events = vec![json!({
        "type": "message.user",
        "payload": {
            "content": [{"type": "text", "text": content}]
        }
    })];
    enrich_interactive_tool_statuses(&mut events);
    assert!(events[0]["payload"].get("messageKind").is_none());
}

#[test]
fn subagent_results_regular_message_untouched() {
    let mut events = vec![make_user_msg("Hello, how are you?")];
    enrich_interactive_tool_statuses(&mut events);
    assert!(events[0]["payload"].get("messageKind").is_none());
}

#[test]
fn subagent_results_partial_marker_no_match() {
    let mut events = vec![make_user_msg(
        "The user mentioned # Completed Sub-Agent Results in their message",
    )];
    enrich_interactive_tool_statuses(&mut events);
    assert!(events[0]["payload"].get("messageKind").is_none());
}

#[test]
fn subagent_results_empty_content_no_match() {
    let mut events = vec![make_user_msg("")];
    enrich_interactive_tool_statuses(&mut events);
    assert!(events[0]["payload"].get("messageKind").is_none());
}

#[test]
fn subagent_results_no_sections_defaults_to_one() {
    // Marker present but no "## [" section headers (malformed content)
    let mut events = vec![make_user_msg(
        "# Completed Sub-Agent Results\n\nSome malformed content without section headers.",
    )];
    enrich_interactive_tool_statuses(&mut events);
    let p = &events[0]["payload"];
    assert_eq!(p["messageKind"], "subagent_results_delivered");
    assert_eq!(p["subagentCount"], 1);
}
