use super::support::*;

#[tokio::test]
async fn archive_releases_worktree() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let (ctx, coord) = make_context_with_worktree(store.clone());

    let sid = ctx
        .session_manager
        .create_session("model", &dir.path().to_string_lossy(), Some("test"), None)
        .unwrap();

    // Acquire worktree
    let result = coord.maybe_acquire(&sid, dir.path()).await.unwrap();
    let wt_path = match result {
        AcquireResult::Acquired(ref info) => info.worktree_path.clone(),
        other => panic!("expected Acquired, got {other:?}"),
    };
    assert!(wt_path.exists(), "worktree dir should exist after acquire");
    assert!(
        coord.get_info(&sid).is_some(),
        "coordinator should track session"
    );

    // Archive via command service
    SessionCommandService::archive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    // Worktree should be released
    assert!(
        coord.get_info(&sid).is_none(),
        "coordinator should no longer track session"
    );
    assert!(!wt_path.exists(), "worktree directory should be removed");

    // worktree.released event should exist
    let events = store
        .get_events_by_type(&sid, &["worktree.released"], None)
        .unwrap();
    assert_eq!(
        events.len(),
        1,
        "should have exactly one worktree.released event"
    );

    // Session should be archived (ended_at set)
    let session = store.get_session(&sid).unwrap().unwrap();
    assert!(session.ended_at.is_some(), "session should be archived");
}

#[tokio::test]
async fn archive_without_worktree_succeeds() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"), None)
        .unwrap();

    SessionCommandService::archive(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    let session = ctx.event_store.get_session(&sid).unwrap().unwrap();
    assert!(session.ended_at.is_some());
}

#[tokio::test]
async fn delete_releases_worktree() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let (ctx, coord) = make_context_with_worktree(store.clone());

    let sid = ctx
        .session_manager
        .create_session("model", &dir.path().to_string_lossy(), Some("test"), None)
        .unwrap();

    let result = coord.maybe_acquire(&sid, dir.path()).await.unwrap();
    let wt_path = match result {
        AcquireResult::Acquired(ref info) => info.worktree_path.clone(),
        other => panic!("expected Acquired, got {other:?}"),
    };
    assert!(wt_path.exists());

    SessionCommandService::delete(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    assert!(
        coord.get_info(&sid).is_none(),
        "coordinator should no longer track session"
    );
    assert!(!wt_path.exists(), "worktree directory should be removed");

    // Session should be fully deleted
    assert!(
        store.get_session(&sid).unwrap().is_none(),
        "session should be deleted"
    );
}

#[tokio::test]
async fn delete_without_worktree_succeeds() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"), None)
        .unwrap();

    SessionCommandService::delete(&Deps::from_test_context(&ctx), sid.clone())
        .await
        .unwrap();

    assert!(ctx.event_store.get_session(&sid).unwrap().is_none());
}
