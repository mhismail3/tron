use super::*;
use crate::shared::protocol::events::TronEvent;

#[tokio::test]
async fn session_title_actuator_persists_and_broadcasts_explicit_metadata() {
    let (runtime, _home) = test_runtime(None);
    let created = runtime
        .event_store
        .create_session("mock", "/tmp", Some("New Session"), None)
        .unwrap();
    let session_id = created.session.id;
    let mut events = runtime.orchestrator.subscribe();

    let result = runtime
        .set_session_title(session_id.clone(), "  Durable Worker Title  ".to_owned())
        .await
        .unwrap();

    assert_eq!(result["sessionId"], session_id);
    assert_eq!(result["title"], "Durable Worker Title");
    assert_eq!(result["updated"], true);
    assert_eq!(
        runtime
            .event_store
            .get_session(&session_id)
            .unwrap()
            .unwrap()
            .title
            .as_deref(),
        Some("Durable Worker Title")
    );
    let event = events.recv().await.unwrap();
    assert!(matches!(
        event,
        TronEvent::SessionUpdated { title: Some(title), .. }
            if title == "Durable Worker Title"
    ));
}
