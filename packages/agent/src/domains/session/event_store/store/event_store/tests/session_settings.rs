use super::*;

#[test]
fn model_selection_updates_metadata_and_appends_one_idempotent_event() {
    let store = setup();
    let created = store
        .create_session("gpt-5.6-luna", "/tmp/model-selection", None, Some("openai"))
        .unwrap();

    assert_eq!(
        store
            .update_latest_model(&created.session.id, "gpt-5.6-sol")
            .unwrap(),
        ("gpt-5.6-luna".to_owned(), true)
    );
    assert_eq!(
        store
            .update_latest_model(&created.session.id, "gpt-5.6-sol")
            .unwrap(),
        ("gpt-5.6-sol".to_owned(), false)
    );

    let session = store.get_session(&created.session.id).unwrap().unwrap();
    assert_eq!(session.latest_model, "gpt-5.6-sol");
    let rows = store
        .get_events_by_type(
            &created.session.id,
            &[EventType::SessionModelChanged.as_str()],
            None,
        )
        .unwrap();
    assert_eq!(rows.len(), 1);
    let payloads = store.resolve_event_payloads(&rows).unwrap();
    assert_eq!(payloads[0]["previousModel"], "gpt-5.6-luna");
    assert_eq!(payloads[0]["newModel"], "gpt-5.6-sol");
}

#[test]
fn reasoning_selection_is_an_indexed_latest_value_and_a_complete_audit_trail() {
    let store = setup();
    let created = store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/reasoning-selection",
            None,
            Some("openai"),
        )
        .unwrap();

    assert_eq!(
        store
            .update_reasoning_level(&created.session.id, "gpt-5.6-sol", "medium")
            .unwrap(),
        (None, true)
    );
    assert_eq!(
        store
            .update_reasoning_level(&created.session.id, "gpt-5.6-sol", "medium")
            .unwrap(),
        (Some("medium".to_owned()), false)
    );
    assert_eq!(
        store
            .update_reasoning_level(&created.session.id, "gpt-5.6-sol", "high")
            .unwrap(),
        (Some("medium".to_owned()), true)
    );

    let rows = store
        .get_events_by_type(
            &created.session.id,
            &[EventType::SessionReasoningChanged.as_str()],
            None,
        )
        .unwrap();
    assert_eq!(rows.len(), 2);
    let payloads = store.resolve_event_payloads(&rows).unwrap();
    assert_eq!(payloads[0]["newLevel"], "medium");
    assert_eq!(payloads[1]["previousLevel"], "medium");
    assert_eq!(payloads[1]["newLevel"], "high");
}

#[test]
fn reasoning_selection_rejects_a_concurrent_model_change_without_writing() {
    let store = setup();
    let created = store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/reasoning-model-race",
            None,
            Some("openai"),
        )
        .unwrap();
    store
        .update_latest_model(&created.session.id, "gpt-5.6-luna")
        .unwrap();

    let error = store
        .update_reasoning_level(&created.session.id, "gpt-5.6-sol", "high")
        .unwrap_err();
    assert!(error.to_string().contains("session model changed"));
    let rows = store
        .get_events_by_type(
            &created.session.id,
            &[EventType::SessionReasoningChanged.as_str()],
            None,
        )
        .unwrap();
    assert!(rows.is_empty());
}
