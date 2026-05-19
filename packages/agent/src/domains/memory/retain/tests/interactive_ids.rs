use super::support::*;

#[test]
fn collect_interactive_ids_finds_user_interaction() {
    let msgs = vec![assistant_capability_invocation("agent::ask_user", "aq_1")];
    let ids = collect_interactive_capability_invocation_ids(&msgs);
    assert!(ids.contains("aq_1"));
    assert_eq!(ids.len(), 1);
}

#[test]
fn collect_interactive_ids_finds_execute_wrapped_user_interaction() {
    let msgs = vec![assistant_capability_invocation_with_input(
        "execute",
        "aq_1",
        json!({
            "mode": "invoke",
            "contractId": "agent::ask_user",
            "payload": {"questions": [{"question": "Proceed?"}]}
        }),
    )];
    let ids = collect_interactive_capability_invocation_ids(&msgs);
    assert!(ids.contains("aq_1"));
    assert_eq!(ids.len(), 1);
}

#[test]
fn collect_interactive_ids_ignores_non_interactive_capabilities() {
    let msgs = vec![
        assistant_capability_invocation("filesystem::read_file", "r_1"),
        assistant_capability_invocation("process::run", "b_1"),
    ];
    let ids = collect_interactive_capability_invocation_ids(&msgs);
    assert!(
        ids.is_empty(),
        "should not collect non-interactive capability ids"
    );
}

#[test]
fn collect_interactive_ids_mixed_capability_invocation() {
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([
            {"type": "capability_invocation", "id": "aq_1", "name": "agent::ask_user", "input": {}},
            {"type": "capability_invocation", "id": "r_1", "name": "filesystem::read_file", "input": {}}
        ]),
        invocation_id: None,
        is_error: None,
    }];
    let ids = collect_interactive_capability_invocation_ids(&msgs);
    assert!(ids.contains("aq_1"));
    assert!(!ids.contains("r_1"));
    assert_eq!(ids.len(), 1);
}

#[test]
fn collect_interactive_ids_string_content_skipped_safely() {
    let msgs = vec![Message {
        role: "user".to_string(),
        content: json!("plain string content"),
        invocation_id: None,
        is_error: None,
    }];
    let ids = collect_interactive_capability_invocation_ids(&msgs);
    assert!(ids.is_empty());
}

#[test]
fn collect_interactive_ids_block_without_type_field() {
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([{"name": "agent::ask_user", "id": "aq_1"}]),
        invocation_id: None,
        is_error: None,
    }];
    let ids = collect_interactive_capability_invocation_ids(&msgs);
    assert!(ids.is_empty(), "blocks without type field must be ignored");
}

#[test]
fn collect_interactive_ids_capability_invocation_without_id() {
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([{"type": "capability_invocation", "name": "agent::ask_user"}]),
        invocation_id: None,
        is_error: None,
    }];
    let ids = collect_interactive_capability_invocation_ids(&msgs);
    assert!(
        ids.is_empty(),
        "capability_invocation without id produces no entry"
    );
}

#[test]
fn collect_interactive_ids_multiple_ask_user_calls() {
    let msgs = vec![
        assistant_capability_invocation("agent::ask_user", "aq_1"),
        assistant_capability_invocation("agent::ask_user", "aq_2"),
        assistant_capability_invocation("agent::ask_user", "aq_3"),
    ];
    let ids = collect_interactive_capability_invocation_ids(&msgs);
    assert_eq!(ids.len(), 3);
    assert!(ids.contains("aq_1"));
    assert!(ids.contains("aq_2"));
    assert!(ids.contains("aq_3"));
}
