use super::support::*;

#[test]
fn serialize_empty_messages_returns_empty_string() {
    let out = serialize_for_memory(&[]);
    assert_eq!(out, "");
}

#[test]
fn serialize_handles_string_content_message() {
    let msgs = vec![user_text("hi there")];
    let out = serialize_for_memory(&msgs);
    assert!(out.contains("[USER] hi there"), "got: {out}");
}

#[test]
fn serialize_filters_user_interaction_result_but_keeps_question_text() {
    let msgs = vec![
        assistant_user_interaction("aq_1", &["What's your favorite color?"]),
        capability_result(
            "aq_1",
            "Q1: What's your favorite color? [single] (Red, Blue)",
        ),
        user_text("Red"),
    ];
    let out = serialize_for_memory(&msgs);
    // Verbose capability_result recap is filtered.
    assert!(
        !out.contains("[CAPABILITY_RESULT]"),
        "interactive capability_result should be filtered: {out}"
    );
    // Option list noise stays out.
    assert!(
        !out.contains("(Red, Blue)"),
        "option list from recap should not appear: {out}"
    );
    // But the question context survives via the assistant line.
    assert!(
        out.contains("[ASSISTANT] Asked: \"What's your favorite color?\""),
        "question context should appear in assistant line: {out}"
    );
    // And the user's answer is preserved.
    assert!(out.contains("[USER] Red"), "user answer preserved: {out}");
}

#[test]
fn serialize_retains_non_interactive_capability_result() {
    let msgs = vec![
        assistant_capability_invocation("filesystem::read_file", "r_1"),
        capability_result("r_1", "file contents here"),
    ];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("[CAPABILITY_RESULT] file contents here"),
        "non-interactive capability result should appear: {out}"
    );
}

#[test]
fn serialize_filters_multiple_interactive_in_slice() {
    let msgs = vec![
        assistant_capability_invocation("agent::ask_user", "aq_1"),
        capability_result("aq_1", "Q1: first"),
        user_text("a1"),
        assistant_capability_invocation("agent::ask_user", "aq_2"),
        capability_result("aq_2", "Q2: second"),
        user_text("a2"),
        assistant_capability_invocation("agent::ask_user", "aq_3"),
        capability_result("aq_3", "Q3: third"),
        user_text("a3"),
    ];
    let out = serialize_for_memory(&msgs);
    assert!(
        !out.contains("[CAPABILITY_RESULT]"),
        "all three should be filtered: {out}"
    );
    assert!(!out.contains("Q1:"), "no question echo: {out}");
    assert!(!out.contains("Q2:"), "no question echo: {out}");
    assert!(!out.contains("Q3:"), "no question echo: {out}");
    assert!(out.contains("[USER] a1"));
    assert!(out.contains("[USER] a2"));
    assert!(out.contains("[USER] a3"));
}

#[test]
fn serialize_keeps_orphan_capability_result() {
    // Capability result whose invocation_id has no matching capability_invocation in the slice.
    // Default: preserve it — we only filter when we can confidently identify
    // the source as interactive.
    let msgs = vec![capability_result("orphan_id", "some capability output")];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("[CAPABILITY_RESULT] some capability output"),
        "orphan capability_result should be preserved: {out}"
    );
}

#[test]
fn serialize_preserves_mixed_interactive_and_regular() {
    let msgs = vec![
        assistant_capability_invocation("agent::ask_user", "aq_1"),
        capability_result("aq_1", "Q1: pick one"),
        user_text("done"),
        assistant_capability_invocation("filesystem::read_file", "r_1"),
        capability_result("r_1", "file body"),
        assistant_text("final thoughts"),
    ];
    let out = serialize_for_memory(&msgs);
    assert!(!out.contains("pick one"), "interactive filtered: {out}");
    assert!(
        out.contains("[CAPABILITY_RESULT] file body"),
        "filesystem read kept: {out}"
    );
    assert!(out.contains("[ASSISTANT] final thoughts"));
    assert!(out.contains("[USER] done"));
}

#[test]
fn serialize_flags_errored_non_interactive_capability_result() {
    let msgs = vec![
        assistant_capability_invocation("process::run", "b_1"),
        Message {
            role: "capability_result".to_string(),
            content: json!([{"type": "text", "text": "command failed"}]),
            invocation_id: Some("b_1".to_string()),
            is_error: Some(true),
        },
    ];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("[CAPABILITY_ERROR] command failed"),
        "error label preserved: {out}"
    );
}

#[test]
fn extract_summary_returns_none_for_text_block() {
    let block = json!({"type": "text", "text": "hello"});
    assert_eq!(extract_interactive_capability_summary(&block), None);
}

#[test]
fn extract_summary_returns_none_for_non_interactive_capability_invocation() {
    let block = json!({
        "type": "capability_invocation",
        "id": "r_1",
        "name": "filesystem::read_file",
        "input": {"path": "/tmp/x"}
    });
    assert_eq!(extract_interactive_capability_summary(&block), None);
}

#[test]
fn extract_summary_returns_none_when_input_missing() {
    let block = json!({
        "type": "capability_invocation",
        "id": "aq_1",
        "name": "agent::ask_user"
    });
    assert_eq!(extract_interactive_capability_summary(&block), None);
}

#[test]
fn extract_summary_ask_user_single_question() {
    let block = json!({
        "type": "capability_invocation",
        "id": "aq_1",
        "name": "agent::ask_user",
        "input": {
            "questions": [{"question": "What's next?", "options": [{"label":"A"},{"label":"B"}], "mode":"single"}]
        }
    });
    assert_eq!(
        extract_interactive_capability_summary(&block),
        Some("Asked: \"What's next?\"".to_string())
    );
}

#[test]
fn extract_summary_execute_wrapped_ask_user_single_question() {
    let block = json!({
        "type": "capability_invocation",
        "id": "aq_1",
        "name": "execute",
        "input": {
            "mode": "invoke",
            "contractId": "agent::ask_user",
            "payload": {
                "questions": [{"question": "Continue?", "options": [{"label":"Yes"}]}]
            }
        }
    });
    assert_eq!(
        extract_interactive_capability_summary(&block),
        Some("Asked: \"Continue?\"".to_string())
    );
}

#[test]
fn extract_summary_ask_user_multiple_questions_joined() {
    let block = json!({
        "type": "capability_invocation",
        "id": "aq_1",
        "name": "agent::ask_user",
        "input": {
            "questions": [
                {"question": "Q one?", "options": [{"label":"A"},{"label":"B"}]},
                {"question": "Q two?", "options": [{"label":"X"},{"label":"Y"}]}
            ]
        }
    });
    let out = extract_interactive_capability_summary(&block).unwrap();
    assert_eq!(out, "Asked: \"Q one?\"; \"Q two?\"");
}

#[test]
fn extract_summary_ask_user_without_questions_returns_none() {
    let block = json!({
        "type": "capability_invocation",
        "id": "aq_1",
        "name": "agent::ask_user",
        "input": {"questions": []}
    });
    assert_eq!(extract_interactive_capability_summary(&block), None);
}

#[test]
fn extract_summary_ask_user_omits_options_and_mode() {
    // Options, modes, and context should NOT appear in the summary — they
    // are the upstream source of transcript pollution. Only the question
    // text itself is preserved.
    let block = json!({
        "type": "capability_invocation",
        "id": "aq_1",
        "name": "agent::ask_user",
        "input": {
            "questions": [{
                "question": "Pick color",
                "options": [{"label": "Crimson"}, {"label": "Cerulean"}],
                "mode": "single"
            }],
            "context": "ratification gate"
        }
    });
    let out = extract_interactive_capability_summary(&block).unwrap();
    assert!(!out.contains("Crimson"), "options should be omitted: {out}");
    assert!(
        !out.contains("Cerulean"),
        "options should be omitted: {out}"
    );
    assert!(!out.contains("[single]"), "mode should be omitted: {out}");
    assert!(
        !out.contains("ratification"),
        "context should be omitted: {out}"
    );
}

#[test]
fn serialize_preserves_multi_question_ask_user_transcript() {
    let msgs = vec![
        assistant_user_interaction(
            "aq_1",
            &["What's your role?", "What timezone?", "What language?"],
        ),
        capability_result("aq_1", "verbose recap"),
        user_text("IC; PT; Swift"),
    ];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("Asked: \"What's your role?\""),
        "q1 missing: {out}"
    );
    assert!(out.contains("\"What timezone?\""), "q2 missing: {out}");
    assert!(out.contains("\"What language?\""), "q3 missing: {out}");
    assert!(
        !out.contains("[CAPABILITY_RESULT]"),
        "verbose recap leaked: {out}"
    );
    assert!(out.contains("[USER] IC; PT; Swift"));
}

#[test]
fn serialize_assistant_mixes_text_and_interactive_summary() {
    // The agent often writes a short intro text block before the capability_invocation
    // in the same message. Both should appear on the transcript line.
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([
            {"type": "text", "text": "Let me ask you something."},
            {"type": "capability_invocation", "id": "aq_1", "name": "agent::ask_user", "input": {
                "questions": [{"question": "Ready?", "options": [{"label":"Y"},{"label":"N"}]}]
            }}
        ]),
        invocation_id: None,
        is_error: None,
    }];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("Let me ask you something"),
        "text block missing: {out}"
    );
    assert!(
        out.contains("Asked: \"Ready?\""),
        "question text missing: {out}"
    );
}

#[test]
fn serialize_ignores_non_interactive_capability_invocation_in_assistant_content() {
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([
            {"type": "text", "text": "reading file"},
            {"type": "capability_invocation", "id": "r_1", "name": "filesystem::read_file", "input": {"path": "/tmp/x"}}
        ]),
        invocation_id: None,
        is_error: None,
    }];
    let out = serialize_for_memory(&msgs);
    assert!(out.contains("[ASSISTANT] reading file"));
    assert!(!out.contains("Asked:"));
    assert!(!out.contains("Requested confirmation"));
}
