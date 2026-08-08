use super::*;

#[test]
fn user_input_state_is_derived_from_canonical_events() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/user-input", None, None)
        .unwrap();
    let session_id = &session.session.id;

    assert_eq!(
        store
            .user_input_request_state(session_id, "question-1")
            .unwrap(),
        UserInputRequestState::Missing
    );

    store
        .append(&AppendOptions {
            session_id,
            event_type: EventType::ToolInvocationStarted,
            payload: serde_json::json!({
                "invocationId":"question-1",
                "toolName":"request_user_input",
                "arguments":{
                    "questions":[{
                        "header":"Format",
                        "id":"format",
                        "question":"Which format?",
                        "options":[
                            {"label":"Markdown","description":"Markdown file"},
                            {"label":"HTML","description":"HTML file"}
                        ]
                    }]
                },
                "turn":1
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    store
        .append(&AppendOptions {
            session_id,
            event_type: EventType::ToolInvocationCompleted,
            payload: serde_json::json!({
                "invocationId":"question-1",
                "toolName":"request_user_input",
                "content":"Question presented",
                "isError":false,
                "duration":1
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    assert_eq!(
        store
            .user_input_request_state(session_id, "question-1")
            .unwrap(),
        UserInputRequestState::Pending
    );
    assert_eq!(
        store
            .user_input_request_arguments(session_id, "question-1")
            .unwrap()
            .unwrap()["questions"][0]["id"],
        "format"
    );

    let answer = serde_json::json!({
        "content":"Question answered",
        "messageKind":"user_input_answer",
        "toolName":"request_user_input_answer",
        "invocationId":"question-1",
        "answers":[{"questionId":"format","selectedLabel":"Markdown"}]
    });
    store
        .append(&AppendOptions {
            session_id,
            event_type: EventType::MessageUser,
            payload: answer.clone(),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    assert_eq!(
        store
            .user_input_request_state(session_id, "question-1")
            .unwrap(),
        UserInputRequestState::Answered
    );

    let duplicate = store.append(&AppendOptions {
        session_id,
        event_type: EventType::MessageUser,
        payload: answer,
        parent_id: None,
        sequence: None,
    });
    assert!(
        duplicate.is_err(),
        "one invocation accepts exactly one answer"
    );
}

#[test]
fn failed_user_input_completion_does_not_open_a_request() {
    let store = setup();
    let session = store
        .create_session("model", "/tmp/user-input-failure", None, None)
        .unwrap();
    store
        .append(&AppendOptions {
            session_id: &session.session.id,
            event_type: EventType::ToolInvocationCompleted,
            payload: serde_json::json!({
                "invocationId":"question-failed",
                "toolName":"request_user_input",
                "content":"Invalid question",
                "isError":true,
                "duration":1
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    assert_eq!(
        store
            .user_input_request_state(&session.session.id, "question-failed")
            .unwrap(),
        UserInputRequestState::Missing
    );
}
