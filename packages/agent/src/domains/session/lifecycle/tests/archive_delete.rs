use super::support::*;

#[tokio::test]
async fn archive_without_external_workspace_succeeds() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"))
        .unwrap();

    SessionLifecycleService::archive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
    assert!(session.ended_at.is_some());
}

#[tokio::test]
async fn delete_without_external_workspace_succeeds() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"))
        .unwrap();

    SessionLifecycleService::delete(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    assert!(ctx.event_store.get_session(&sid).unwrap().is_none());
}
