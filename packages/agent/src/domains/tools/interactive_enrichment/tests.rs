use super::enrich_interactive_tool_statuses;
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

// ── message.user back-fill ────────────────────────────────────────

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
