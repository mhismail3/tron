use super::support::*;

#[tokio::test]
async fn archive_older_than_archives_stale_and_preserves_fresh() {
    let ctx = make_test_context();

    let stale = ctx
        .session_manager
        .create_session("m", "/tmp", Some("stale"))
        .unwrap();
    let fresh = ctx
        .session_manager
        .create_session("m", "/tmp", Some("fresh"))
        .unwrap();

    let ten_days_ago = (chrono::Utc::now() - chrono::Duration::days(10)).to_rfc3339();
    set_last_activity(&ctx.event_store, &stale, &ten_days_ago);

    let result = SessionLifecycleService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();

    assert_eq!(result["archivedCount"].as_u64().unwrap(), 1);
    let ids: Vec<&str> = result["archivedSessionIds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(ids, vec![stale.as_str()]);

    let stale_row = ctx.event_store.get_session(&stale).unwrap().unwrap();
    let fresh_row = ctx.event_store.get_session(&fresh).unwrap().unwrap();
    assert!(stale_row.ended_at.is_some(), "stale should be archived");
    assert!(fresh_row.ended_at.is_none(), "fresh should stay active");
}

#[tokio::test]
async fn archive_older_than_skips_already_archived() {
    let ctx = make_test_context();

    let s1 = ctx
        .session_manager
        .create_session("m", "/tmp", Some("s1"))
        .unwrap();

    // Pre-archive s1 by hand.
    SessionLifecycleService::archive(&Deps::from_test_context(&ctx), s1.clone())
        .await
        .unwrap();

    let ten_days_ago = (chrono::Utc::now() - chrono::Duration::days(10)).to_rfc3339();
    set_last_activity(&ctx.event_store, &s1, &ten_days_ago);

    let result = SessionLifecycleService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();
    assert_eq!(result["archivedCount"].as_u64().unwrap(), 0);
    assert!(result["archivedSessionIds"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn archive_older_than_zero_days_archives_all_active() {
    let ctx = make_test_context();

    let a = ctx
        .session_manager
        .create_session("m", "/tmp", Some("a"))
        .unwrap();
    let b = ctx
        .session_manager
        .create_session("m", "/tmp", Some("b"))
        .unwrap();

    // Force both timestamps to the past so they unambiguously precede
    // the cutoff even on very fast machines.
    let one_hour_ago = (chrono::Utc::now() - chrono::Duration::hours(1)).to_rfc3339();
    set_last_activity(&ctx.event_store, &a, &one_hour_ago);
    set_last_activity(&ctx.event_store, &b, &one_hour_ago);

    let result = SessionLifecycleService::archive_older_than(&Deps::from_test_context(&ctx), 0)
        .await
        .unwrap();
    assert_eq!(result["archivedCount"].as_u64().unwrap(), 2);

    for sid in [&a, &b] {
        let row = ctx.event_store.get_session(sid).unwrap().unwrap();
        assert!(row.ended_at.is_some(), "session {sid} should be archived");
    }
}

#[tokio::test]
async fn archive_older_than_returns_cutoff_in_the_past() {
    let ctx = make_test_context();
    let now = chrono::Utc::now();
    let result = SessionLifecycleService::archive_older_than(&Deps::from_test_context(&ctx), 30)
        .await
        .unwrap();
    let cutoff_str = result["cutoff"].as_str().unwrap();
    let cutoff: chrono::DateTime<chrono::Utc> = cutoff_str.parse().unwrap();
    assert!(cutoff < now, "cutoff {cutoff:?} must precede now {now:?}");
    let delta = now - cutoff;
    assert!(
        delta.num_days() >= 29 && delta.num_days() <= 31,
        "cutoff delta {} days",
        delta.num_days()
    );
}

#[tokio::test]
async fn archive_older_than_on_empty_store_returns_zero() {
    let ctx = make_test_context();
    let result = SessionLifecycleService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();
    assert_eq!(result["archivedCount"].as_u64().unwrap(), 0);
    assert!(result["archivedSessionIds"].as_array().unwrap().is_empty());
    assert!(result["skipped"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn archive_older_than_archives_batch_multiple_stale() {
    let ctx = make_test_context();

    let a = ctx
        .session_manager
        .create_session("m", "/tmp", Some("a"))
        .unwrap();
    let b = ctx
        .session_manager
        .create_session("m", "/tmp", Some("b"))
        .unwrap();
    let c = ctx
        .session_manager
        .create_session("m", "/tmp", Some("c"))
        .unwrap();

    let old = (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();
    for sid in [&a, &b, &c] {
        set_last_activity(&ctx.event_store, sid, &old);
    }

    let result = SessionLifecycleService::archive_older_than(&Deps::from_test_context(&ctx), 7)
        .await
        .unwrap();
    assert_eq!(result["archivedCount"].as_u64().unwrap(), 3);

    let archived: std::collections::HashSet<&str> = result["archivedSessionIds"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert!(archived.contains(a.as_str()));
    assert!(archived.contains(b.as_str()));
    assert!(archived.contains(c.as_str()));
}
